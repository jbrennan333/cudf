/*
 * Copyright (c) 2019-2021, NVIDIA CORPORATION.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#include <cudf/column/column_device_view.cuh>
#include <cudf/column/column_factories.hpp>
#include <cudf/detail/get_value.cuh>
#include <cudf/detail/null_mask.hpp>
#include <cudf/detail/utilities/cuda.cuh>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/strings/detail/concatenate.hpp>
#include <cudf/strings/detail/utilities.hpp>
#include <cudf/strings/strings_column_view.hpp>
#include <cudf/table/table_device_view.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/binary_search.h>
#include <thrust/execution_policy.h>
#include <thrust/transform_scan.h>

namespace cudf {
namespace strings {
namespace detail {
// Benchmark data, shared at https://github.com/rapidsai/cudf/pull/4703, shows
// that the single kernel optimization generally performs better, but when the
// number of chars/col is beyond a certain threshold memcpy performs better.
// This heuristic estimates which strategy will give better performance by
// comparing the mean chars/col with values from the above table.
constexpr bool use_fused_kernel_heuristic(bool const has_nulls,
                                          size_t const total_bytes,
                                          size_t const num_columns)
{
  return has_nulls ? total_bytes < num_columns * 1572864  // midpoint of 1048576 and 2097152
                   : total_bytes < num_columns * 393216;  // midpoint of 262144 and 524288
}

// Using a functor instead of a lambda as a workaround for:
// error: The enclosing parent function ("create_strings_device_views") for an
// extended __device__ lambda must not have deduced return type
struct chars_size_transform {
  __device__ size_t operator()(column_device_view const& col) const
  {
    if (col.size() > 0) {
      constexpr auto offsets_index = strings_column_view::offsets_column_index;
      auto d_offsets               = col.child(offsets_index).data<int32_t>();
      return d_offsets[col.size() + col.offset()] - d_offsets[col.offset()];
    } else {
      return 0;
    }
  }
};

auto create_strings_device_views(host_span<column_view const> views, rmm::cuda_stream_view stream)
{
  CUDF_FUNC_RANGE();
  // Assemble contiguous array of device views
  std::unique_ptr<rmm::device_buffer> device_view_owners;
  column_device_view* device_views_ptr;
  std::tie(device_view_owners, device_views_ptr) =
    contiguous_copy_column_device_views<column_device_view>(views, stream);

  // Compute the partition offsets and size of offset column
  // Note: Using 64-bit size_t so we can detect overflow of 32-bit size_type
  auto input_offsets = std::vector<size_t>(views.size() + 1);
  auto offset_it     = std::next(input_offsets.begin());
  thrust::transform(
    thrust::host, views.begin(), views.end(), offset_it, [](auto const& col) -> size_t {
      return static_cast<size_t>(col.size());
    });
  thrust::inclusive_scan(thrust::host, offset_it, input_offsets.end(), offset_it);
  auto d_input_offsets   = cudf::detail::make_device_uvector_async(input_offsets, stream);
  auto const output_size = input_offsets.back();

  // Compute the partition offsets and size of chars column
  // Note: Using 64-bit size_t so we can detect overflow of 32-bit size_type
  auto d_partition_offsets = rmm::device_uvector<size_t>(views.size() + 1, stream);
  d_partition_offsets.set_element_to_zero_async(0, stream);  // zero first element

  thrust::transform_inclusive_scan(rmm::exec_policy(stream),
                                   device_views_ptr,
                                   device_views_ptr + views.size(),
                                   std::next(d_partition_offsets.begin()),
                                   chars_size_transform{},
                                   thrust::plus<size_t>{});
  auto const output_chars_size = d_partition_offsets.back_element(stream);
  stream.synchronize();  // ensure copy of output_chars_size is complete before returning

  return std::make_tuple(std::move(device_view_owners),
                         device_views_ptr,
                         std::move(d_input_offsets),
                         std::move(d_partition_offsets),
                         output_size,
                         output_chars_size);
}

template <size_type block_size, bool Nullable>
__global__ void fused_concatenate_string_offset_kernel(column_device_view const* input_views,
                                                       size_t const* input_offsets,
                                                       size_t const* partition_offsets,
                                                       size_type const num_input_views,
                                                       size_type const output_size,
                                                       int32_t* output_data,
                                                       bitmask_type* output_mask,
                                                       size_type* out_valid_count)
{
  size_type output_index     = threadIdx.x + blockIdx.x * blockDim.x;
  size_type warp_valid_count = 0;

  unsigned active_mask;
  if (Nullable) { active_mask = __ballot_sync(0xFFFF'FFFF, output_index < output_size); }
  while (output_index < output_size) {
    // Lookup input index by searching for output index in offsets
    // thrust::prev isn't in CUDA 10.0, so subtracting 1 here instead
    auto const offset_it =
      -1 + thrust::upper_bound(
             thrust::seq, input_offsets, input_offsets + num_input_views, output_index);
    size_type const partition_index = offset_it - input_offsets;

    auto const offset_index      = output_index - *offset_it;
    auto const& input_view       = input_views[partition_index];
    constexpr auto offsets_child = strings_column_view::offsets_column_index;
    auto const* input_data       = input_view.child(offsets_child).data<int32_t>();
    output_data[output_index] =
      input_data[offset_index + input_view.offset()]  // handle parent offset
      - input_data[input_view.offset()]               // subract first offset if non-zero
      + partition_offsets[partition_index];           // add offset of source column

    if (Nullable) {
      bool const bit_is_set       = input_view.is_valid(offset_index);
      bitmask_type const new_word = __ballot_sync(active_mask, bit_is_set);

      // First thread writes bitmask word
      if (threadIdx.x % cudf::detail::warp_size == 0) {
        output_mask[word_index(output_index)] = new_word;
      }

      warp_valid_count += __popc(new_word);
    }

    output_index += blockDim.x * gridDim.x;
    if (Nullable) { active_mask = __ballot_sync(active_mask, output_index < output_size); }
  }

  // Fill final offsets index with total size of char data
  if (output_index == output_size) {
    output_data[output_size] = partition_offsets[num_input_views];
  }

  if (Nullable) {
    using cudf::detail::single_lane_block_sum_reduce;
    auto block_valid_count = single_lane_block_sum_reduce<block_size, 0>(warp_valid_count);
    if (threadIdx.x == 0) { atomicAdd(out_valid_count, block_valid_count); }
  }
}

__global__ void fused_concatenate_string_chars_kernel(column_device_view const* input_views,
                                                      size_t const* partition_offsets,
                                                      size_type const num_input_views,
                                                      size_type const output_size,
                                                      char* output_data)
{
  size_type output_index = threadIdx.x + blockIdx.x * blockDim.x;

  while (output_index < output_size) {
    // Lookup input index by searching for output index in offsets
    // thrust::prev isn't in CUDA 10.0, so subtracting 1 here instead
    auto const offset_it =
      -1 + thrust::upper_bound(
             thrust::seq, partition_offsets, partition_offsets + num_input_views, output_index);
    size_type const partition_index = offset_it - partition_offsets;

    auto const offset_index = output_index - *offset_it;
    auto const& input_view  = input_views[partition_index];

    constexpr auto offsets_child   = strings_column_view::offsets_column_index;
    auto const* input_offsets_data = input_view.child(offsets_child).data<int32_t>();

    constexpr auto chars_child   = strings_column_view::chars_column_index;
    auto const* input_chars_data = input_view.child(chars_child).data<char>();

    auto const first_char     = input_offsets_data[input_view.offset()];
    output_data[output_index] = input_chars_data[offset_index + first_char];

    output_index += blockDim.x * gridDim.x;
  }
}

std::unique_ptr<column> concatenate(host_span<column_view const> columns,
                                    rmm::cuda_stream_view stream,
                                    rmm::mr::device_memory_resource* mr)
{
  CUDF_FUNC_RANGE();
  // Compute output sizes
  auto const device_views         = create_strings_device_views(columns, stream);
  auto const& d_views             = std::get<1>(device_views);
  auto const& d_input_offsets     = std::get<2>(device_views);
  auto const& d_partition_offsets = std::get<3>(device_views);
  auto const strings_count        = std::get<4>(device_views);
  auto const total_bytes          = std::get<5>(device_views);
  auto const offsets_count        = strings_count + 1;

  if (strings_count == 0) { return make_empty_column(data_type{type_id::STRING}); }

  CUDF_EXPECTS(offsets_count <= static_cast<std::size_t>(std::numeric_limits<size_type>::max()),
               "total number of strings is too large for cudf column");
  CUDF_EXPECTS(total_bytes <= static_cast<std::size_t>(std::numeric_limits<size_type>::max()),
               "total size of strings is too large for cudf column");

  bool const has_nulls =
    std::any_of(columns.begin(), columns.end(), [](auto const& col) { return col.has_nulls(); });

  // create chars column
  auto chars_column = create_chars_child_column(total_bytes, stream, mr);
  auto d_new_chars  = chars_column->mutable_view().data<char>();
  chars_column->set_null_count(0);

  // create offsets column
  auto offsets_column = make_numeric_column(
    data_type{type_id::INT32}, offsets_count, mask_state::UNALLOCATED, stream, mr);
  auto d_new_offsets = offsets_column->mutable_view().data<int32_t>();
  offsets_column->set_null_count(0);

  rmm::device_buffer null_mask{0, stream, mr};
  size_type null_count{};
  if (has_nulls) {
    null_mask =
      cudf::detail::create_null_mask(strings_count, mask_state::UNINITIALIZED, stream, mr);
  }

  {  // Copy offsets columns with single kernel launch
    rmm::device_scalar<size_type> d_valid_count(0, stream);

    constexpr size_type block_size{256};
    cudf::detail::grid_1d config(offsets_count, block_size);
    auto const kernel = has_nulls ? fused_concatenate_string_offset_kernel<block_size, true>
                                  : fused_concatenate_string_offset_kernel<block_size, false>;
    kernel<<<config.num_blocks, config.num_threads_per_block, 0, stream.value()>>>(
      d_views,
      d_input_offsets.data(),
      d_partition_offsets.data(),
      static_cast<size_type>(columns.size()),
      strings_count,
      d_new_offsets,
      reinterpret_cast<bitmask_type*>(null_mask.data()),
      d_valid_count.data());

    if (has_nulls) { null_count = strings_count - d_valid_count.value(stream); }
  }

  if (total_bytes > 0) {
    // Use a heuristic to guess when the fused kernel will be faster than memcpy
    if (use_fused_kernel_heuristic(has_nulls, total_bytes, columns.size())) {
      // Use single kernel launch to copy chars columns
      constexpr size_type block_size{256};
      cudf::detail::grid_1d config(total_bytes, block_size);
      auto const kernel = fused_concatenate_string_chars_kernel;
      kernel<<<config.num_blocks, config.num_threads_per_block, 0, stream.value()>>>(
        d_views,
        d_partition_offsets.data(),
        static_cast<size_type>(columns.size()),
        total_bytes,
        d_new_chars);
    } else {
      // Memcpy each input chars column (more efficient for very large strings)
      for (auto column = columns.begin(); column != columns.end(); ++column) {
        size_type column_size = column->size();
        if (column_size == 0)  // nothing to do
          continue;            // empty column may not have children
        size_type column_offset   = column->offset();
        column_view offsets_child = column->child(strings_column_view::offsets_column_index);
        column_view chars_child   = column->child(strings_column_view::chars_column_index);

        auto bytes_offset =
          cudf::detail::get_value<offset_type>(offsets_child, column_offset, stream);

        // copy the chars column data
        auto d_chars = chars_child.data<char>() + bytes_offset;
        auto const bytes =
          cudf::detail::get_value<offset_type>(offsets_child, column_size + column_offset, stream) -
          bytes_offset;

        CUDA_TRY(
          cudaMemcpyAsync(d_new_chars, d_chars, bytes, cudaMemcpyDeviceToDevice, stream.value()));

        // get ready for the next column
        d_new_chars += bytes;
      }
    }
  }

  return make_strings_column(strings_count,
                             std::move(offsets_column),
                             std::move(chars_column),
                             null_count,
                             std::move(null_mask),
                             stream,
                             mr);
}

}  // namespace detail
}  // namespace strings
}  // namespace cudf

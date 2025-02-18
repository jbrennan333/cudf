/*
 * Copyright (c) 2020-2021, NVIDIA CORPORATION.
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

/**
 * @file reader_impl.cu
 * @brief cuDF-IO JSON reader class implementation
 */

#include "reader_impl.hpp"

#include <io/comp/io_uncomp.h>
#include <io/utilities/parsing_utils.cuh>
#include <io/utilities/type_conversion.cuh>

#include <cudf/column/column_factories.hpp>
#include <cudf/detail/utilities/vector_factories.hpp>
#include <cudf/detail/utilities/visitor_overload.hpp>
#include <cudf/groupby.hpp>
#include <cudf/sorting.hpp>
#include <cudf/strings/detail/replace.hpp>
#include <cudf/table/table.hpp>
#include <cudf/utilities/error.hpp>
#include <cudf/utilities/span.hpp>
#include <io/utilities/trie.cuh>

#include <rmm/cuda_stream_view.hpp>
#include <rmm/device_scalar.hpp>
#include <rmm/exec_policy.hpp>

#include <thrust/optional.h>

using cudf::host_span;

namespace cudf {
namespace io {
namespace detail {
namespace json {
using namespace cudf::io;

namespace {
/**
 * @brief Estimates the maximum expected length or a row, based on the number
 * of columns
 *
 * If the number of columns is not available, it will return a value large
 * enough for most use cases
 *
 * @param[in] num_columns Number of columns in the JSON file (optional)
 *
 * @return Estimated maximum size of a row, in bytes
 */
constexpr size_t calculate_max_row_size(int num_columns = 0) noexcept
{
  constexpr size_t max_row_bytes = 16 * 1024;  // 16KB
  constexpr size_t column_bytes  = 64;
  constexpr size_t base_padding  = 1024;  // 1KB
  return num_columns == 0
           ? max_row_bytes  // Use flat size if the # of columns is not known
           : base_padding +
               num_columns * column_bytes;  // Expand size based on the # of columns, if available
}

}  // anonymous namespace

/**
 * @brief Aggregate the table containing keys info by their hash values.
 *
 * @param[in] info Table with columns containing key offsets, lengths and hashes, respectively
 *
 * @return Table with data aggregated by key hash values
 */
std::unique_ptr<table> aggregate_keys_info(std::unique_ptr<table> info)
{
  auto const info_view = info->view();
  std::vector<groupby::aggregation_request> requests;
  requests.emplace_back(groupby::aggregation_request{info_view.column(0)});
  requests.back().aggregations.emplace_back(make_min_aggregation<groupby_aggregation>());
  requests.back().aggregations.emplace_back(make_nth_element_aggregation<groupby_aggregation>(0));

  requests.emplace_back(groupby::aggregation_request{info_view.column(1)});
  requests.back().aggregations.emplace_back(make_min_aggregation<groupby_aggregation>());
  requests.back().aggregations.emplace_back(make_nth_element_aggregation<groupby_aggregation>(0));

  // Aggregate by hash values
  groupby::groupby gb_obj(
    table_view({info_view.column(2)}), null_policy::EXCLUDE, sorted::NO, {}, {});

  auto result = gb_obj.aggregate(requests);  // TODO: no stream parameter?

  std::vector<std::unique_ptr<column>> out_columns;
  out_columns.emplace_back(std::move(result.second[0].results[0]));  // offsets
  out_columns.emplace_back(std::move(result.second[1].results[0]));  // lengths
  out_columns.emplace_back(std::move(result.first->release()[0]));   // hashes
  return std::make_unique<table>(std::move(out_columns));
}

/**
 * @brief Initializes the (key hash -> column index) hash map.
 */
col_map_ptr_type create_col_names_hash_map(column_view column_name_hashes,
                                           rmm::cuda_stream_view stream)
{
  auto key_col_map{col_map_type::create(column_name_hashes.size(), stream)};
  auto const column_data = column_name_hashes.data<uint32_t>();
  thrust::for_each_n(rmm::exec_policy(stream),
                     thrust::make_counting_iterator<size_type>(0),
                     column_name_hashes.size(),
                     [map = *key_col_map, column_data] __device__(size_type idx) mutable {
                       map.insert(thrust::make_pair(column_data[idx], idx));
                     });
  return key_col_map;
}

/**
 * @brief Create a table whose columns contain the information on JSON objects' keys.
 *
 * The columns contain name offsets in the file, name lengths and name hashes, respectively.
 *
 * @param[in] options Parsing options (e.g. delimiter and quotation character)
 * @param[in] data Input JSON device data
 * @param[in] row_offsets Device array of row start locations in the input buffer
 * @param[in] stream CUDA stream used for device memory operations and kernel launches
 *
 * @return std::unique_ptr<table> cudf table with three columns (offsets, lengths, hashes)
 */
std::unique_ptr<table> create_json_keys_info_table(const parse_options_view& options,
                                                   device_span<char const> const data,
                                                   device_span<uint64_t const> const row_offsets,
                                                   rmm::cuda_stream_view stream)
{
  // Count keys
  rmm::device_scalar<unsigned long long int> key_counter(0, stream);
  cudf::io::json::gpu::collect_keys_info(
    options, data, row_offsets, key_counter.data(), {}, stream);

  // Allocate columns to store hash value, length, and offset of each JSON object key in the input
  auto const num_keys = key_counter.value(stream);
  std::vector<std::unique_ptr<column>> info_columns;
  info_columns.emplace_back(make_numeric_column(data_type(type_id::UINT64), num_keys));
  info_columns.emplace_back(make_numeric_column(data_type(type_id::UINT16), num_keys));
  info_columns.emplace_back(make_numeric_column(data_type(type_id::UINT32), num_keys));
  // Create a table out of these columns to pass them around more easily
  auto info_table           = std::make_unique<table>(std::move(info_columns));
  auto const info_table_mdv = mutable_table_device_view::create(info_table->mutable_view(), stream);

  // Reset the key counter - now used for indexing
  key_counter.set_value_to_zero_async(stream);
  // Fill the allocated columns
  cudf::io::json::gpu::collect_keys_info(
    options, data, row_offsets, key_counter.data(), {*info_table_mdv}, stream);
  return info_table;
}

/**
 * @brief Extract the keys from the JSON file the name offsets/lengths.
 */
std::vector<std::string> create_key_strings(char const* h_data,
                                            table_view sorted_info,
                                            rmm::cuda_stream_view stream)
{
  auto const num_cols = sorted_info.num_rows();
  std::vector<uint64_t> h_offsets(num_cols);
  cudaMemcpyAsync(h_offsets.data(),
                  sorted_info.column(0).data<uint64_t>(),
                  sizeof(uint64_t) * num_cols,
                  cudaMemcpyDefault,
                  stream.value());

  std::vector<uint16_t> h_lens(num_cols);
  cudaMemcpyAsync(h_lens.data(),
                  sorted_info.column(1).data<uint16_t>(),
                  sizeof(uint16_t) * num_cols,
                  cudaMemcpyDefault,
                  stream.value());

  std::vector<std::string> names(num_cols);
  std::transform(h_offsets.cbegin(),
                 h_offsets.cend(),
                 h_lens.cbegin(),
                 names.begin(),
                 [&](auto offset, auto len) { return std::string(h_data + offset, len); });
  return names;
}

auto sort_keys_info_by_offset(std::unique_ptr<table> info)
{
  auto const agg_offset_col_view = info->get_column(0).view();
  return sort_by_key(info->view(), table_view({agg_offset_col_view}));
}

/**
 * @brief Extract JSON object keys from a JSON file.
 *
 * @param[in] stream CUDA stream used for device memory operations and kernel launches.
 *
 * @return Names of JSON object keys in the file
 */
std::pair<std::vector<std::string>, col_map_ptr_type> reader::impl::get_json_object_keys_hashes(
  device_span<uint64_t const> rec_starts, rmm::cuda_stream_view stream)
{
  auto info = create_json_keys_info_table(
    opts_.view(),
    device_span<char const>(static_cast<char const*>(data_.data()), data_.size()),
    rec_starts,
    stream);

  auto aggregated_info = aggregate_keys_info(std::move(info));
  auto sorted_info     = sort_keys_info_by_offset(std::move(aggregated_info));

  return {create_key_strings(uncomp_data_, sorted_info->view(), stream),
          create_col_names_hash_map(sorted_info->get_column(2).view(), stream)};
}

/**
 * @brief Ingest input JSON file/buffer, without decompression.
 *
 * Sets the sources_, byte_range_offset_, and byte_range_size_ data members
 *
 * @param[in] range_offset Number of bytes offset from the start
 * @param[in] range_size Bytes to read; use `0` for all remaining data
 */
void reader::impl::ingest_raw_input(size_t range_offset, size_t range_size)
{
  size_t map_range_size = 0;
  if (range_size != 0) {
    auto const dtype_option_size =
      std::visit([](const auto& dtypes) { return dtypes.size(); }, options_.get_dtypes());
    map_range_size = range_size + calculate_max_row_size(dtype_option_size);
  }

  // Support delayed opening of the file if using memory mapping datasource
  // This allows only mapping of a subset of the file if using byte range
  if (sources_.empty()) {
    assert(!filepaths_.empty());
    for (const auto& path : filepaths_) {
      sources_.emplace_back(datasource::create(path, range_offset, map_range_size));
    }
  }

  // Iterate through the user defined sources and read the contents into the local buffer
  CUDF_EXPECTS(!sources_.empty(), "No sources were defined");
  size_t total_source_size = 0;
  for (const auto& source : sources_) {
    total_source_size += source->size();
  }
  total_source_size = total_source_size - range_offset;

  buffer_.resize(total_source_size);
  size_t bytes_read = 0;
  for (const auto& source : sources_) {
    if (!source->is_empty()) {
      auto data_size = (map_range_size != 0) ? map_range_size : source->size();
      bytes_read += source->host_read(range_offset, data_size, &buffer_[bytes_read]);
    }
  }

  byte_range_offset_ = range_offset;
  byte_range_size_   = range_size;
  load_whole_file_   = byte_range_offset_ == 0 && byte_range_size_ == 0;
}

/**
 * @brief Decompress the input data, if needed
 *
 * Sets the uncomp_data_ and uncomp_size_ data members
 * Loads the data into device memory if byte range parameters are not used
 */
void reader::impl::decompress_input(rmm::cuda_stream_view stream)
{
  const auto compression_type =
    infer_compression_type(options_.get_compression(),
                           filepaths_.size() > 0 ? filepaths_[0] : "",
                           {{"gz", "gzip"}, {"zip", "zip"}, {"bz2", "bz2"}, {"xz", "xz"}});
  if (compression_type == "none") {
    // Do not use the owner vector here to avoid extra copy
    uncomp_data_ = reinterpret_cast<const char*>(buffer_.data());
    uncomp_size_ = buffer_.size();
  } else {
    uncomp_data_owner_ = get_uncompressed_data(  //
      host_span<char const>(                     //
        reinterpret_cast<const char*>(buffer_.data()),
        buffer_.size()),
      compression_type);

    uncomp_data_ = uncomp_data_owner_.data();
    uncomp_size_ = uncomp_data_owner_.size();
  }
  if (load_whole_file_) data_ = rmm::device_buffer(uncomp_data_, uncomp_size_, stream);
}

rmm::device_uvector<uint64_t> reader::impl::find_record_starts(rmm::cuda_stream_view stream)
{
  std::vector<char> chars_to_count{'\n'};
  // Currently, ignoring lineterminations within quotes is handled by recording the records of both,
  // and then filtering out the records that is a quotechar or a linetermination within a quotechar
  // pair.
  if (allow_newlines_in_strings_) { chars_to_count.push_back('\"'); }
  // If not starting at an offset, add an extra row to account for the first row in the file
  cudf::size_type prefilter_count = ((byte_range_offset_ == 0) ? 1 : 0);
  if (load_whole_file_) {
    prefilter_count += count_all_from_set(data_, chars_to_count, stream);
  } else {
    prefilter_count += count_all_from_set(uncomp_data_, uncomp_size_, chars_to_count, stream);
  }

  rmm::device_uvector<uint64_t> rec_starts(prefilter_count, stream);

  auto* find_result_ptr = rec_starts.data();
  // Manually adding an extra row to account for the first row in the file
  if (byte_range_offset_ == 0) {
    find_result_ptr++;
    CUDA_TRY(cudaMemsetAsync(rec_starts.data(), 0ull, sizeof(uint64_t), stream.value()));
  }

  std::vector<char> chars_to_find{'\n'};
  if (allow_newlines_in_strings_) { chars_to_find.push_back('\"'); }
  // Passing offset = 1 to return positions AFTER the found character
  if (load_whole_file_) {
    find_all_from_set(data_, chars_to_find, 1, find_result_ptr, stream);
  } else {
    find_all_from_set(uncomp_data_, uncomp_size_, chars_to_find, 1, find_result_ptr, stream);
  }

  // Previous call stores the record pinput_file.typeositions as encountered by all threads
  // Sort the record positions as subsequent processing may require filtering
  // certain rows or other processing on specific records
  thrust::sort(rmm::exec_policy(stream), rec_starts.begin(), rec_starts.end());

  auto filtered_count = prefilter_count;
  if (allow_newlines_in_strings_) {
    auto h_rec_starts = cudf::detail::make_std_vector_sync(rec_starts, stream);
    bool quotation    = false;
    for (cudf::size_type i = 1; i < prefilter_count; ++i) {
      if (uncomp_data_[h_rec_starts[i] - 1] == '\"') {
        quotation       = !quotation;
        h_rec_starts[i] = uncomp_size_;
        filtered_count--;
      } else if (quotation) {
        h_rec_starts[i] = uncomp_size_;
        filtered_count--;
      }
    }
    CUDA_TRY(cudaMemcpyAsync(rec_starts.data(),
                             h_rec_starts.data(),
                             h_rec_starts.size() * sizeof(uint64_t),
                             cudaMemcpyDefault,
                             stream.value()));
    thrust::sort(rmm::exec_policy(stream), rec_starts.begin(), rec_starts.end());
    stream.synchronize();
  }

  // Exclude the ending newline as it does not precede a record start
  if (uncomp_data_[uncomp_size_ - 1] == '\n') { filtered_count--; }
  rec_starts.resize(filtered_count, stream);

  return rec_starts;
}

/**
 * @brief Uploads the relevant segment of the input json data onto the GPU.
 *
 * Sets the d_data_ data member.
 * Only rows that need to be parsed are copied, based on the byte range
 * Also updates the array of record starts to match the device data offset.
 */
void reader::impl::upload_data_to_device(rmm::device_uvector<uint64_t>& rec_starts,
                                         rmm::cuda_stream_view stream)
{
  size_t start_offset = 0;
  size_t end_offset   = uncomp_size_;

  // Trim lines that are outside range
  if (byte_range_size_ != 0 || byte_range_offset_ != 0) {
    auto h_rec_starts = cudf::detail::make_std_vector_sync(rec_starts, stream);

    if (byte_range_size_ != 0) {
      auto it = h_rec_starts.end() - 1;
      while (it >= h_rec_starts.begin() && *it > byte_range_size_) {
        end_offset = *it;
        --it;
      }
      h_rec_starts.erase(it + 1, h_rec_starts.end());
    }

    // Resize to exclude rows outside of the range
    // Adjust row start positions to account for the data subcopy
    start_offset = h_rec_starts.front();
    rec_starts.resize(h_rec_starts.size(), stream);
    thrust::transform(rmm::exec_policy(stream),
                      rec_starts.begin(),
                      rec_starts.end(),
                      thrust::make_constant_iterator(start_offset),
                      rec_starts.begin(),
                      thrust::minus<uint64_t>());
  }

  const size_t bytes_to_upload = end_offset - start_offset;
  CUDF_EXPECTS(bytes_to_upload <= uncomp_size_,
               "Error finding the record within the specified byte range.\n");

  // Upload the raw data that is within the rows of interest
  data_ = rmm::device_buffer(uncomp_data_ + start_offset, bytes_to_upload, stream);
}

void reader::impl::set_column_names(device_span<uint64_t const> rec_starts,
                                    rmm::cuda_stream_view stream)
{
  // If file only contains one row, use the file size for the row size
  uint64_t first_row_len = data_.size() / sizeof(char);
  if (rec_starts.size() > 1) {
    // Set first_row_len to the offset of the second row, if it exists
    CUDA_TRY(cudaMemcpyAsync(&first_row_len,
                             rec_starts.data() + 1,
                             sizeof(uint64_t),
                             cudaMemcpyDeviceToHost,
                             stream.value()));
  }
  std::vector<char> first_row(first_row_len);
  CUDA_TRY(cudaMemcpyAsync(first_row.data(),
                           data_.data(),
                           first_row_len * sizeof(char),
                           cudaMemcpyDeviceToHost,
                           stream.value()));
  stream.synchronize();

  // Determine the row format between:
  //   JSON array - [val1, val2, ...] and
  //   JSON object - {"col1":val1, "col2":val2, ...}
  // based on the top level opening bracket
  const auto first_square_bracket = std::find(first_row.begin(), first_row.end(), '[');
  const auto first_curly_bracket  = std::find(first_row.begin(), first_row.end(), '{');
  CUDF_EXPECTS(first_curly_bracket != first_row.end() || first_square_bracket != first_row.end(),
               "Input data is not a valid JSON file.");
  // If the first opening bracket is '{', assume object format
  if (first_curly_bracket < first_square_bracket) {
    // use keys as column names if input rows are objects
    auto keys_desc         = get_json_object_keys_hashes(rec_starts, stream);
    metadata_.column_names = keys_desc.first;
    set_column_map(std::move(keys_desc.second), stream);
  } else {
    int cols_found = 0;
    bool quotation = false;
    for (size_t pos = 0; pos < first_row.size(); ++pos) {
      // Flip the quotation flag if current character is a quotechar
      if (first_row[pos] == opts_.quotechar) {
        quotation = !quotation;
      }
      // Check if end of a column/row
      else if (pos == first_row.size() - 1 || (!quotation && first_row[pos] == opts_.delimiter)) {
        metadata_.column_names.emplace_back(std::to_string(cols_found++));
      }
    }
  }
}

void reader::impl::set_data_types(device_span<uint64_t const> rec_starts,
                                  rmm::cuda_stream_view stream)
{
  bool has_to_infer_column_types =
    std::visit([](const auto& dtypes) { return dtypes.empty(); }, options_.get_dtypes());
  if (!has_to_infer_column_types) {
    dtypes_ = std::visit(cudf::detail::visitor_overload{
                           [&](const std::vector<data_type>& dtypes) {
                             CUDF_EXPECTS(dtypes.size() == metadata_.column_names.size(),
                                          "Must specify types for all columns");
                             return dtypes;
                           },
                           [&](const std::map<std::string, data_type>& dtypes) {
                             std::vector<data_type> sorted_dtypes;
                             std::transform(std::cbegin(metadata_.column_names),
                                            std::cend(metadata_.column_names),
                                            std::back_inserter(sorted_dtypes),
                                            [&](auto const& column_name) {
                                              auto const it = dtypes.find(column_name);
                                              CUDF_EXPECTS(it != dtypes.end(),
                                                           "Must specify types for all columns");
                                              return it->second;
                                            });
                             return sorted_dtypes;
                           }},
                         options_.get_dtypes());
  } else {
    CUDF_EXPECTS(rec_starts.size() != 0, "No data available for data type inference.\n");
    auto const num_columns       = metadata_.column_names.size();
    auto const do_set_null_count = key_to_col_idx_map_ != nullptr;

    auto const h_column_infos = cudf::io::json::gpu::detect_data_types(
      opts_.view(),
      device_span<char const>(static_cast<char const*>(data_.data()), data_.size()),
      rec_starts,
      do_set_null_count,
      num_columns,
      get_column_map_device_ptr(),
      stream);

    auto get_type_id = [&](auto const& cinfo) {
      auto int_count_total =
        cinfo.big_int_count + cinfo.negative_small_int_count + cinfo.positive_small_int_count;
      if (cinfo.null_count == static_cast<int>(rec_starts.size())) {
        // Entire column is NULL; allocate the smallest amount of memory
        return type_id::INT8;
      } else if (cinfo.string_count > 0) {
        return type_id::STRING;
      } else if (cinfo.datetime_count > 0) {
        return type_id::TIMESTAMP_MILLISECONDS;
      } else if (cinfo.float_count > 0 || (int_count_total > 0 && cinfo.null_count > 0)) {
        return type_id::FLOAT64;
      } else if (cinfo.big_int_count == 0 && int_count_total != 0) {
        return type_id::INT64;
      } else if (cinfo.big_int_count != 0 && cinfo.negative_small_int_count != 0) {
        return type_id::STRING;
      } else if (cinfo.big_int_count != 0) {
        return type_id::UINT64;
      } else if (cinfo.bool_count > 0) {
        return type_id::BOOL8;
      } else {
        CUDF_FAIL("Data type detection failed.\n");
      }
    };

    std::transform(std::cbegin(h_column_infos),
                   std::cend(h_column_infos),
                   std::back_inserter(dtypes_),
                   [&](auto const& cinfo) { return data_type{get_type_id(cinfo)}; });
  }
}

table_with_metadata reader::impl::convert_data_to_table(device_span<uint64_t const> rec_starts,
                                                        rmm::cuda_stream_view stream)
{
  const auto num_columns = dtypes_.size();
  const auto num_records = rec_starts.size();

  // alloc output buffers.
  std::vector<column_buffer> out_buffers;
  for (size_t col = 0; col < num_columns; ++col) {
    out_buffers.emplace_back(dtypes_[col], num_records, true, stream, mr_);
  }

  thrust::host_vector<data_type> h_dtypes(num_columns);
  thrust::host_vector<void*> h_data(num_columns);
  thrust::host_vector<bitmask_type*> h_valid(num_columns);

  for (size_t i = 0; i < num_columns; ++i) {
    h_dtypes[i] = dtypes_[i];
    h_data[i]   = out_buffers[i].data();
    h_valid[i]  = out_buffers[i].null_mask();
  }

  auto d_dtypes = cudf::detail::make_device_uvector_async<data_type>(h_dtypes, stream);
  auto d_data   = cudf::detail::make_device_uvector_async<void*>(h_data, stream);
  auto d_valid  = cudf::detail::make_device_uvector_async<cudf::bitmask_type*>(h_valid, stream);
  auto d_valid_counts =
    cudf::detail::make_zeroed_device_uvector_async<cudf::size_type>(num_columns, stream);

  cudf::io::json::gpu::convert_json_to_columns(
    opts_.view(),
    device_span<char const>(static_cast<char const*>(data_.data()), data_.size()),
    rec_starts,
    d_dtypes,
    get_column_map_device_ptr(),
    d_data,
    d_valid,
    d_valid_counts,
    stream);

  stream.synchronize();

  // postprocess columns
  auto target_chars   = std::vector<char>{'\\', '"', '\\', '\\', '\\', 't', '\\', 'r', '\\', 'b'};
  auto target_offsets = std::vector<size_type>{0, 2, 4, 6, 8, 10};

  auto repl_chars   = std::vector<char>{'"', '\\', '\t', '\r', '\b'};
  auto repl_offsets = std::vector<size_type>{0, 1, 2, 3, 4, 5};

  auto target = make_strings_column(cudf::detail::make_device_uvector_async(target_chars, stream),
                                    cudf::detail::make_device_uvector_async(target_offsets, stream),
                                    {},
                                    0,
                                    stream);
  auto repl   = make_strings_column(cudf::detail::make_device_uvector_async(repl_chars, stream),
                                  cudf::detail::make_device_uvector_async(repl_offsets, stream),
                                  {},
                                  0,
                                  stream);

  auto const h_valid_counts = cudf::detail::make_std_vector_sync(d_valid_counts, stream);
  std::vector<std::unique_ptr<column>> out_columns;
  for (size_t i = 0; i < num_columns; ++i) {
    out_buffers[i].null_count() = num_records - h_valid_counts[i];

    auto out_column = make_column(out_buffers[i], nullptr, stream, mr_);
    if (out_column->type().id() == type_id::STRING) {
      // Need to remove escape character in case of '\"' and '\\'
      out_columns.emplace_back(cudf::strings::detail::replace(
        out_column->view(), target->view(), repl->view(), stream, mr_));
    } else {
      out_columns.emplace_back(std::move(out_column));
    }
  }

  // This is to ensure the stream-ordered make_stream_column calls above complete before
  // the temporary std::vectors are destroyed on exit from this function.
  stream.synchronize();

  CUDF_EXPECTS(!out_columns.empty(), "No columns created from json input");

  return table_with_metadata{std::make_unique<table>(std::move(out_columns)), metadata_};
}

reader::impl::impl(std::vector<std::unique_ptr<datasource>>&& sources,
                   std::vector<std::string> const& filepaths,
                   json_reader_options const& options,
                   rmm::cuda_stream_view stream,
                   rmm::mr::device_memory_resource* mr)
  : options_(options), mr_(mr), sources_(std::move(sources)), filepaths_(filepaths)
{
  CUDF_EXPECTS(options_.is_enabled_lines(), "Only JSON Lines format is currently supported.\n");

  opts_.trie_true  = cudf::detail::create_serialized_trie({"true"}, stream);
  opts_.trie_false = cudf::detail::create_serialized_trie({"false"}, stream);
  opts_.trie_na    = cudf::detail::create_serialized_trie({"", "null"}, stream);

  opts_.dayfirst = options.is_enabled_dayfirst();
}

/**
 * @brief Read an entire set or a subset of data from the source
 *
 * @param[in] range_offset Number of bytes offset from the start
 * @param[in] range_size Bytes to read; use `0` for all remaining data
 * @param[in] stream CUDA stream used for device memory operations and kernel launches.
 *
 * @return Table and its metadata
 */
table_with_metadata reader::impl::read(json_reader_options const& options,
                                       rmm::cuda_stream_view stream)
{
  auto range_offset = options.get_byte_range_offset();
  auto range_size   = options.get_byte_range_size();

  ingest_raw_input(range_offset, range_size);
  CUDF_EXPECTS(buffer_.size() != 0, "Ingest failed: input data is null.\n");

  decompress_input(stream);
  CUDF_EXPECTS(uncomp_data_ != nullptr, "Ingest failed: uncompressed input data is null.\n");
  CUDF_EXPECTS(uncomp_size_ != 0, "Ingest failed: uncompressed input data has zero size.\n");

  auto rec_starts = find_record_starts(stream);
  CUDF_EXPECTS(!rec_starts.is_empty(), "Error enumerating records.\n");

  upload_data_to_device(rec_starts, stream);
  CUDF_EXPECTS(data_.size() != 0, "Error uploading input data to the GPU.\n");

  set_column_names(rec_starts, stream);
  CUDF_EXPECTS(!metadata_.column_names.empty(), "Error determining column names.\n");

  set_data_types(rec_starts, stream);
  CUDF_EXPECTS(!dtypes_.empty(), "Error in data type detection.\n");

  return convert_data_to_table(rec_starts, stream);
}

// Forward to implementation
reader::reader(std::vector<std::string> const& filepaths,
               json_reader_options const& options,
               rmm::cuda_stream_view stream,
               rmm::mr::device_memory_resource* mr)
{
  // Delay actual instantiation of data source until read to allow for
  // partial memory mapping of file using byte ranges
  std::vector<std::unique_ptr<datasource>> src = {};  // Empty datasources
  _impl = std::make_unique<impl>(std::move(src), filepaths, options, stream, mr);
}

// Forward to implementation
reader::reader(std::vector<std::unique_ptr<cudf::io::datasource>>&& sources,
               json_reader_options const& options,
               rmm::cuda_stream_view stream,
               rmm::mr::device_memory_resource* mr)
{
  std::vector<std::string> file_paths = {};  // Empty filepaths
  _impl = std::make_unique<impl>(std::move(sources), file_paths, options, stream, mr);
}

// Destructor within this translation unit
reader::~reader() = default;

// Forward to implementation
table_with_metadata reader::read(json_reader_options const& options, rmm::cuda_stream_view stream)
{
  return table_with_metadata{_impl->read(options, stream)};
}
}  // namespace json
}  // namespace detail
}  // namespace io
}  // namespace cudf

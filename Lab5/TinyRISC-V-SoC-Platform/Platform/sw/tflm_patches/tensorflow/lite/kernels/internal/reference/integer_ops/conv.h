/* Copyright 2019 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

#include <algorithm>

#include "lab5_api.h"
#include "perf.h"
#include "tensorflow/lite/kernels/internal/common.h"
#include "tensorflow/lite/kernels/internal/portable_tensor_utils.h"

namespace tflite
{
namespace reference_integer_ops
{

// Fixed-point per-channel-quantization convolution reference kernel.
inline void do_conv(const ConvParams &params, const int32_t *output_multiplier,
                    const int32_t *output_shift, const RuntimeShape &input_shape, const int8_t *input_data, const RuntimeShape &filter_shape, const int8_t *filter_data, const RuntimeShape &bias_shape, const int32_t *bias_data, const RuntimeShape &output_shape, int8_t *output_data)
{
    // Get parameters.
    const int32_t input_offset = params.input_offset; // r = s(q - Z)

    const int stride_width = params.stride_width;
    const int stride_height = params.stride_height;
    const int dilation_width_factor = params.dilation_width_factor;
    const int dilation_height_factor = params.dilation_height_factor;
    const int pad_width = params.padding_values.width;
    const int pad_height = params.padding_values.height;
    const int32_t output_offset = params.output_offset;
    // Set min and max value of the output.
    const int32_t output_activation_min = params.quantized_activation_min;
    const int32_t output_activation_max = params.quantized_activation_max;
    // Consistency check.
    TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
    TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
    TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
    TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
    const int batches = MatchingDim(input_shape, 0, output_shape, 0);
    const int input_depth = input_shape.Dims(3);
    const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
    if (bias_data)
    {
        TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
    }

    // Check dimensions of the tensors.
    const int input_height = input_shape.Dims(1);
    const int input_width = input_shape.Dims(2);
    const int filter_height = filter_shape.Dims(1);
    const int filter_width = filter_shape.Dims(2);
    const int filter_input_depth = filter_shape.Dims(3);
    const int groups = input_depth / filter_input_depth;
    TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
    const int filters_per_group = output_depth / groups;
    const int output_height = output_shape.Dims(1);
    const int output_width = output_shape.Dims(2);
    // 打包 filters 與 patch，再分批交給 TPU 計算。
    const int full_k = filter_height * filter_width * filter_input_depth;
    static uint32_t packed_patch[65536];
    static uint32_t packed_filter[65536];
    static int32_t channel_bias[4096];
    static int32_t partial[252];
    static int32_t accum[252];
    // 每次 GEMV 的 K <= 254，A 最多 1024 words；M 取 4 的倍數。
    const int tile_limit = std::min(254, full_k);
    const int block_rows = tile_limit > 0 ? std::min(252, 4 * (1024 / tile_limit)) : 0;
    const int rows_per_group = (filters_per_group + 3) / 4;
    const uint64_t packed_word_count = static_cast<uint64_t>(groups) * rows_per_group * full_k;

    const bool use_packed = tile_limit > 0 && full_k <= 65536 && output_depth <= 4096 && packed_word_count <= 65536 && input_offset >= -127 && input_offset <= 128;

    // packed filter：每次 Conv 只打包一次。
    // 排列：group -> 一批 channels -> 一段 K -> 四列一組 -> k。
    if (use_packed)
    {
        for (int out_channel = 0; out_channel < output_depth; ++out_channel)
        {
            const int group = out_channel / filters_per_group;
            const int channel_in_group = out_channel % filters_per_group;
            const int channel_block = (channel_in_group / block_rows) * block_rows;
            const int M = std::min(block_rows, filters_per_group - channel_block);
            const int row = channel_in_group - channel_block;
            const int lane = row % 4;
            int32_t filter_sum = 0;
            for (int filter_y = 0; filter_y < filter_height; ++filter_y)
            {
                for (int filter_x = 0; filter_x < filter_width; ++filter_x)
                {
                    for (int in_channel = 0; in_channel < filter_input_depth; ++in_channel)
                    {
                        const int k = (filter_y * filter_width + filter_x) * filter_input_depth + in_channel;
                        const int kb = (k / tile_limit) * tile_limit;
                        const int tile_k = std::min(tile_limit, full_k - kb);
                        // 保留你的走訪順序，用索引將 weight 放進分塊後的位置。
                        const int packed_index = group * rows_per_group * full_k + (channel_block / 4) * full_k + ((M + 3) / 4) * kb + (row / 4) * tile_k + (k - kb);

                        const int8_t weight = filter_data[Offset(filter_shape, out_channel, filter_y, filter_x, in_channel)];
                        filter_sum += weight;

                        // 每組第一個 channel 先清零，未滿四個 channels 的空位也會是 0。
                        if (lane == 0)
                            packed_filter[packed_index] = 0;
                        packed_filter[packed_index] |= static_cast<uint32_t>(static_cast<uint8_t>(weight)) << (24 - 8 * lane);

                    }
                }
            }
            channel_bias[out_channel] = static_cast<int32_t>(static_cast<int64_t>(input_offset) * filter_sum + (bias_data ? bias_data[out_channel] : 0));

        }
    }

    // 同一個位置的 patch，重用於這個 group 的各批 filters。
    if (use_packed)
    {
        // 沿用你的 input_y/input_x 命名：這裡計數 patch 位置，範圍是 output 高寬。
        // 原圖上的取樣座標由 in_y_origin/in_x_origin 加上 y/x 算出。
        for (int batch = 0; batch < batches; ++batch)
        {
            for (int input_y = 0; input_y < output_height; ++input_y)
            {
                const int in_y_origin = input_y * stride_height - pad_height;
                for (int input_x = 0; input_x < output_width; ++input_x)
                {
                    const int in_x_origin = input_x * stride_width - pad_width;
                    for (int group = 0; group < groups; ++group)
                    {
                        for (int y = 0; y < filter_height; ++y)
                        {
                            const int in_y = in_y_origin + y * dilation_height_factor;
                            for (int x = 0; x < filter_width; ++x)
                            {
                                const int in_x = in_x_origin + x * dilation_width_factor;
                                const bool inside = in_y >= 0 && in_y < input_height && in_x >= 0 && in_x < input_width;
                                for (int in_channel = 0; in_channel < filter_input_depth;
                                     ++in_channel)
                                {
                                    const int k = (y * filter_width + x) * filter_input_depth + in_channel;
                                    const int32_t value = inside ? input_data[Offset(input_shape, batch, in_y, in_x, group * filter_input_depth + in_channel)] : -input_offset;

                                    packed_patch[k] = static_cast<uint32_t>(static_cast<uint8_t>(value)) << 24;
                                }
                            }
                        }
                        // patch 已填完，才對各批 output channels 呼叫 GEMV。
                        for (int out_channel = 0; out_channel < filters_per_group; out_channel += block_rows)
                        {
                            const int M = std::min(block_rows, filters_per_group - out_channel);
                            const int row_blocks = (M + 3) / 4;
                            uint32_t* weights = packed_filter + group * rows_per_group * full_k + (out_channel / 4) * full_k;

                            const bool one_tile = full_k <= tile_limit;
                            if (!one_tile)
                                for (int row = 0; row < M; ++row)
                                    accum[row] = 0;
                            for (int kb = 0; kb < full_k; kb += tile_limit)
                            {
                                const int tile_k = std::min(tile_limit, full_k - kb);
                                do_gemv(M, tile_k, weights, packed_patch + kb, partial);
                                weights += row_blocks * tile_k;
                                if (!one_tile)
                                    for (int row = 0; row < M; ++row)
                                        accum[row] += partial[row];
                            }
                            for (int row = 0; row < M; ++row)
                            {
                                const int channel = group * filters_per_group + out_channel + row;
                                const int32_t dot = one_tile ? partial[row] : accum[row];
                                int32_t acc = static_cast<int32_t>(static_cast<uint32_t>(dot) + static_cast<uint32_t>(channel_bias[channel]));

                                acc = MultiplyByQuantizedMultiplier(acc, output_multiplier[channel], output_shift[channel]);

                                acc += output_offset;
                                acc = std::max(acc, output_activation_min);
                                acc = std::min(acc, output_activation_max);
                                output_data[Offset(output_shape, batch, input_y, input_x, channel)] = static_cast<int8_t>(acc);

                            }
                        }
                    }
                }
            }
        }
    }
    else
    {
        // 超出整份暫存容量：每次只打包最多四列、254 個 K，仍由 TPU 計算。
    for (int batch = 0; batch < batches; ++batch)
    {
        for (int out_y = 0; out_y < output_height; ++out_y)
        {
            const int in_y_origin = (out_y * stride_height) - pad_height;
            for (int out_x = 0; out_x < output_width; ++out_x)
            {
                const int in_x_origin = (out_x * stride_width) - pad_width;
                for (int out_channel = 0; out_channel < output_depth;)
                {
                    const int group = out_channel / filters_per_group;
                    const int M =
                        std::min(4, std::min(output_depth - out_channel,
                                             filters_per_group - out_channel % filters_per_group));
                    const int K = filter_height * filter_width * filter_input_depth;
                    // Fixed-size buffers: no malloc or runtime-sized stack arrays.
                    static int8_t patch[254];
                    static int8_t filter_tile[4 * 254];
                    static int32_t gemv_result[4];
                    int32_t accum[4] = {0, 0, 0, 0};

                    for (int k_begin = 0; k_begin < K; k_begin += 254)
                    {
                        const int tile_k = std::min(254, K - k_begin);
                        int in_channel = k_begin % filter_input_depth;
                        int filter_x = (k_begin / filter_input_depth) % filter_width;
                        int filter_y = k_begin / (filter_input_depth * filter_width);

                        int32_t filter_sum[4] = {0, 0, 0, 0};
                        for (int k = 0; k < tile_k; ++k)
                        {
                            // Flatten order: filter_y -> filter_x -> input channel.
                            const int index = k_begin + k;
                            const int in_y = in_y_origin + filter_y * dilation_height_factor;
                            const int in_x = in_x_origin + filter_x * dilation_width_factor;
                            const bool inside =
                                in_y >= 0 && in_y < input_height && in_x >= 0 && in_x < input_width;
                            patch[k] =
                                inside ? input_data[Offset(input_shape, batch, in_y, in_x,
                                                           in_channel + group * filter_input_depth)]
                                       : 0;
                            for (int lane = 0; lane < M; ++lane)
                            {
                                // Omit padding terms by zeroing both the weight and input.
                                const int8_t weight =
                                    inside ? filter_data[(out_channel + lane) * K + index] : 0;
                                filter_tile[lane * tile_k + k] = weight;
                                filter_sum[lane] += weight;
                            }
                            if (++in_channel == filter_input_depth)
                            {
                                in_channel = 0;
                                if (++filter_x == filter_width)
                                {
                                    filter_x = 0;
                                    ++filter_y;
                                }
                            }
                        }
                        // A: M filter rows. B: one input patch. C: M partial sums.
                        uint32_t *filter_pattern = mat2pattern(filter_tile, M, tile_k);
                        uint32_t *input_pattern = vec2pattern(patch, tile_k);
                        do_gemv(M, tile_k, filter_pattern, input_pattern, gemv_result);
                        for (int lane = 0; lane < M; ++lane)
                        {
                            // sum(w * (x + offset)) = sum(w*x) + offset*sum(w).
                            // Apply offset on CPU: x+offset may not fit in int8.
                            accum[lane] += gemv_result[lane] + input_offset * filter_sum[lane];
                        }
                    }

                    for (int lane = 0; lane < M; ++lane)
                    {
                        const int channel = out_channel + lane;
                        int32_t acc = accum[lane];
                        if (bias_data)
                            acc += bias_data[channel];
                        acc = MultiplyByQuantizedMultiplier(acc, output_multiplier[channel],
                                                            output_shift[channel]);
                        acc += output_offset;
                        acc = std::max(acc, output_activation_min);
                        acc = std::min(acc, output_activation_max);
                        output_data[Offset(output_shape, batch, out_y, out_x, channel)] =
                            static_cast<int8_t>(acc);
                    }
                    out_channel += M;
                }
            }
        }
    }

    }
}

inline void ConvPerChannel(const ConvParams &params, const int32_t *output_multiplier,
                           const int32_t *output_shift, const RuntimeShape &input_shape,
                           const int8_t *input_data, const RuntimeShape &filter_shape,
                           const int8_t *filter_data, const RuntimeShape &bias_shape,
                           const int32_t *bias_data, const RuntimeShape &output_shape,
                           int8_t *output_data)
{
    // =====================================================================================================
    // Perf Start:
    // Please do not modify this code, and any code in front of this line in this function is not
    // allowed. If you violated these rules, you will get zero point in this lab.
    uint64_t start = perf_get_mcycle64();
    // =====================================================================================================

    do_conv(params, output_multiplier, output_shift, input_shape, input_data, filter_shape,
            filter_data, bias_shape, bias_data, output_shape, output_data);

    // =====================================================================================================
    // Perf End:
    // Please do not modify this code, and any code behind this line is not allowed.
    // If you violated these rules, you will get zero point in this lab.
    perf_result.add_start(2);
    perf_result.add_result(2, perf_get_mcycle64() - start);
    // =====================================================================================================
}

inline void ConvPerChannelWithPackedInt4Weights(
    const ConvParams &params, const int32_t *output_multiplier, const int32_t *output_shift,
    const RuntimeShape &input_shape, const int8_t *input_data, const RuntimeShape &filter_shape,
    const int8_t *filter_input, int8_t *unpacked_filter_data, const RuntimeShape &bias_shape,
    const int32_t *bias_data, const RuntimeShape &output_shape, int8_t *output_data)
{
    TFLITE_DCHECK(unpacked_filter_data != nullptr);
    tflite::tensor_utils::UnpackDenseInt4IntoInt8(filter_input, filter_shape.FlatSize(),
                                                  unpacked_filter_data);
    ConvPerChannel(params, output_multiplier, output_shift, input_shape, input_data, filter_shape,
                   unpacked_filter_data, bias_shape, bias_data, output_shape, output_data);
}

// Fixed-point per-channel-quantization convolution reference kernel.
// 16-bit data and 8-bit filter
template <typename AccumScalar>
inline void ConvPerChannel(const ConvParams &params, const int32_t *output_multiplier,
                           const int32_t *output_shift, const RuntimeShape &input_shape,
                           const int16_t *input_data, const RuntimeShape &filter_shape,
                           const int8_t *filter_data, const RuntimeShape &bias_shape,
                           const AccumScalar *bias_data, const RuntimeShape &output_shape,
                           int16_t *output_data)
{
    // Get parameters.
    const int stride_width = params.stride_width;
    const int stride_height = params.stride_height;
    const int dilation_width_factor = params.dilation_width_factor;
    const int dilation_height_factor = params.dilation_height_factor;
    const int pad_width = params.padding_values.width;
    const int pad_height = params.padding_values.height;

    // Set min and max value of the output.
    const int32_t output_activation_min = params.quantized_activation_min;
    const int32_t output_activation_max = params.quantized_activation_max;

    // Consistency check.
    TFLITE_DCHECK_LE(output_activation_min, output_activation_max);
    TFLITE_DCHECK_EQ(input_shape.DimensionsCount(), 4);
    TFLITE_DCHECK_EQ(filter_shape.DimensionsCount(), 4);
    TFLITE_DCHECK_EQ(output_shape.DimensionsCount(), 4);
    const int batches = MatchingDim(input_shape, 0, output_shape, 0);
    const int input_depth = input_shape.Dims(3);
    const int output_depth = MatchingDim(filter_shape, 0, output_shape, 3);
    if (bias_data)
    {
        TFLITE_DCHECK_EQ(bias_shape.FlatSize(), output_depth);
    }

    // Check dimensions of the tensors.
    const int input_height = input_shape.Dims(1);
    const int input_width = input_shape.Dims(2);
    const int filter_height = filter_shape.Dims(1);
    const int filter_width = filter_shape.Dims(2);
    const int filter_input_depth = filter_shape.Dims(3);
    const int groups = input_depth / filter_input_depth;
    TFLITE_DCHECK_EQ(input_depth % filter_input_depth, 0);
    const int filters_per_group = output_depth / groups;
    const int output_height = output_shape.Dims(1);
    const int output_width = output_shape.Dims(2);
    for (int batch = 0; batch < batches; ++batch)
    {
        for (int out_y = 0; out_y < output_height; ++out_y)
        {
            const int in_y_origin = (out_y * stride_height) - pad_height;
            for (int out_x = 0; out_x < output_width; ++out_x)
            {
                const int in_x_origin = (out_x * stride_width) - pad_width;
                for (int out_channel = 0; out_channel < output_depth; ++out_channel)
                {
                    auto group = out_channel / filters_per_group;
                    AccumScalar acc = 0;
                    for (int filter_y = 0; filter_y < filter_height; ++filter_y)
                    {
                        const int in_y = in_y_origin + dilation_height_factor * filter_y;
                        for (int filter_x = 0; filter_x < filter_width; ++filter_x)
                        {
                            const int in_x = in_x_origin + dilation_width_factor * filter_x;

                            // Zero padding by omitting the areas outside the image.
                            const bool is_point_inside_image = (in_x >= 0) &&
                                                               (in_x < input_width) &&
                                                               (in_y >= 0) && (in_y < input_height);

                            if (!is_point_inside_image)
                            {
                                continue;
                            }

                            for (int in_channel = 0; in_channel < filter_input_depth; ++in_channel)
                            {
                                int32_t input_val =
                                    input_data[Offset(input_shape, batch, in_y, in_x,
                                                      in_channel + group * filter_input_depth)];
                                int32_t filter_val = filter_data[Offset(
                                    filter_shape, out_channel, filter_y, filter_x, in_channel)];
                                // Accumulate with 64 bits accumulator.
                                // int64_t += int8_t * int16_t so the highest value we can
                                // get from each accumulation is [-127, 127] * ([-32768,
                                // 32767] -
                                // [-32768, 32767]), which is [-8322945, 8322945].
                                // log2(8322945) = 22.99.
                                acc += filter_val * input_val;
                            }
                        }
                    }
                    if (bias_data)
                    {
                        acc += bias_data[out_channel];
                    }
                    int32_t scaled_acc = MultiplyByQuantizedMultiplier(
                        acc, output_multiplier[out_channel], output_shift[out_channel]);
                    scaled_acc = std::max(scaled_acc, output_activation_min);
                    scaled_acc = std::min(scaled_acc, output_activation_max);
                    output_data[Offset(output_shape, batch, out_y, out_x, out_channel)] =
                        static_cast<int16_t>(scaled_acc);
                }
            }
        }
    }
}

} // namespace reference_integer_ops
} // namespace tflite

#endif // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_INTEGER_OPS_CONV_H_

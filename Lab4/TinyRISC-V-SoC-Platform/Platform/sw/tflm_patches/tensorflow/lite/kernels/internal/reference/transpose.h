/* Copyright 2020 The TensorFlow Authors. All Rights Reserved.

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
#ifndef TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_TRANSPOSE_H_
#define TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_TRANSPOSE_H_

#include <array>

#include "tensorflow/lite/kernels/internal/types.h"
#include "perf.h"
#include "cfu.h"
#include "cbo.h"
#include <stdio.h>

namespace tflite
{

  namespace reference_ops
  {

    namespace transpose_internal
    {

      // Recursively explores all the dimensions of the output tensor and writes the
      // corresponding input tensor data.
      //
      // - depth: the current depth of the recursion.
      // - dims: tensor dimension count, also `perm` size.
      // - perm: permutation array.
      // - input_data: Running input data pointer. If depth == num_dims-1, this points
      //               to the first element of the last dimension to traverse.
      // - input_stride: Reverse partial product of input shapes.
      // - output_data: Running output data pointer. If depth == num_dims-1, this
      //                points to the first element of the last dimension to traverse.
      // - output_stride: Reverse partial product of output shapes.
      // - output_shape: Shape of the output tensor.
      //
      // ## Algorithm explanation
      //
      // Assume a 3D tensor T with a shape of [I, J, K] stored in row major order.
      // T[i, j, k] is at position `i*J*K + j*K + k` in the tensor buffer.
      //
      // If we want to go through the whole tensor iteratively, we can use loops.
      //
      // ```
      // for(i = 0; i < I; ++i) {
      //   for(j = 0; j < J; ++j) {
      //     for(k = 0; k < K; ++k) {
      //        T.data[i*J*K + j*K + k] = ...
      //     }
      //   }
      // }
      // ```
      //
      // We can also compute the offset as we go through the loops.
      //
      // ```
      // stride_i = K * J;
      // stride_j = K;
      // stride_k = 1;
      // for(i = 0; i < I; ++i) {
      //   offset_i = i * stride_i;
      //   offset_j = 0;
      //   for(j = 0; j < J; ++j) {
      //     offset_j += stride_j;
      //     offset_k = 0;
      //     for(k = 0; k < K; ++k) {
      //        offset_k += stride_k;
      //        T.data[offset_i + offset_j + offset_k] = ...
      //     }
      //   }
      // }
      // ```
      //
      // This nicely extends to a recursive version which is the base of this
      // algorithm and supports any number of dimensions.
      //
      // ```
      // shape = [I, J, K]
      // strides = [K*J, K, 1]
      // void recurse(T* data, shape, strides, depth = 0) {
      //   if(depth == shape.size) {
      //     *data = ...
      //   } else {
      //     for(a = 0; a < shape[depth]; ++a) {
      //       recurse(data, shape, strides, depth+1);
      //       data += strides[depth];
      //     }
      //   }
      // }
      // ```
      template <typename T>
      void TransposeImpl(const int depth, const int dims, const int32_t *perm,
                         const T *input_data, const int *input_stride, T *output_data,
                         const int *output_stride, const int32_t *output_shape)
      {

        const int dimension_size = output_shape[depth];
        if (depth == dims - 1)
        {
          const int loop_stride = input_stride[perm[depth]];
          for (int i = 0; i < dimension_size; ++i)
          {
            output_data[i] = *input_data;
            input_data += loop_stride;
          }
        }
        else
        {
          for (int i = 0; i < dimension_size; ++i)
          {
            TransposeImpl(depth + 1, dims, perm, input_data, input_stride, output_data, output_stride, output_shape);

            input_data += input_stride[perm[depth]];
            output_data += output_stride[depth];
          }
        }
      }

      // Compile-time switch to get the storage type of the transposition.
      template <int Size>
      struct TransposeStorageType;

      template <>
      struct TransposeStorageType<1>
      {
        using type = int8_t;
      };

      template <>
      struct TransposeStorageType<2>
      {
        using type = int16_t;
      };

      template <>
      struct TransposeStorageType<4>
      {
        using type = int32_t;
      };

      template <>
      struct TransposeStorageType<8>
      {
        using type = int64_t;
      };

      // Sets up the stride arrays for the recursive transpose algorithm.
      //
      // Implementation notes:
      //
      // This is a reverse partial product. We could use standard algorithms to
      // implement this but the result is not a readable and is tricky to get right
      // because the first element must be set to 1, which leads to offset
      // shenanigans:
      //
      // ```
      //   stride[dims - 1] = 1;
      //   std::partial_sum(std::make_reverse_iterator(shape + dims),
      //                    std::make_reverse_iterator(shape + 1),
      //                    stride.rend() - input_rank + 1, std::multiplies());
      // ```
      //
      // Note that Abseil isn't used in kernels implementation. That would make the
      // above solution more readable.
      inline void SetupTransposeStrides(
          std::array<int, kTransposeMaxDimensions> &stride, const int32_t *shape,
          const int dims)
      {
        stride[dims - 1] = 1;
        for (int i = dims - 2; i >= 0; --i)
        {
          stride[i] = stride[i + 1] * shape[i + 1];
        }
      }

      //------------------------------------------------------------------------
      // NPU transpose (CUSTOM-0 funct3 = 5 config, funct3 = 6 start).
      // The NPU loads the whole input into an on-chip buffer, permutes it byte
      // by byte, then burst-writes the output, so the CPU never touches the
      // tensor data. Limits come from the hardware (see NPU.v / Transpose.v).
      //------------------------------------------------------------------------
      constexpr uintptr_t kCacheLineBytes = 32;
      constexpr uint32_t kNpuTransposeMaxBytes = 16384; // NPU TR_BUF_BYTES
      constexpr int kNpuTransposeMaxRank = 6;           // Transpose MAX_RANK

      // funct7 of funct3 = 5. Must be plain macros: cfu_op5 stringifies
      // funct7 into the .insn assembler line.
#define NPU_TR_CFG_ADDR 0       // rs1 = src base, rs2 = dst base
#define NPU_TR_CFG_SIZE 1       // rs1 = rank,     rs2 = total bytes
#define NPU_TR_CFG_DST_SHAPE 2  // rs1 = dim d,    rs2 = output_shape[d]
#define NPU_TR_CFG_SRC_STRIDE 3 // rs1 = dim d,    rs2 = byte stride of input
                                //                 along output dim d

      inline void CleanCacheRange(const void *ptr, uint32_t bytes)
      {
        uintptr_t line = reinterpret_cast<uintptr_t>(ptr) & ~(kCacheLineBytes - 1);
        const uintptr_t end = reinterpret_cast<uintptr_t>(ptr) + bytes;
        for (; line < end; line += kCacheLineBytes)
          cbo_clean(reinterpret_cast<const void *>(line));
      }

      inline void InvalidateCacheRange(const void *ptr, uint32_t bytes)
      {
        uintptr_t line = reinterpret_cast<uintptr_t>(ptr) & ~(kCacheLineBytes - 1);
        const uintptr_t end = reinterpret_cast<uintptr_t>(ptr) + bytes;
        for (; line < end; line += kCacheLineBytes)
          cbo_invalidate(reinterpret_cast<const void *>(line));
      }

      // Runs the transpose on the NPU. Returns false (nothing written) when the
      // shape is outside what the hardware supports, or when the NPU reports an
      // error; the caller then falls back to the software path.
      // Elements wider than 1 byte become one extra innermost dimension of
      // elem_bytes bytes with stride 1, since the NPU permutes single bytes.
      inline bool NpuTranspose(const int dims, const int32_t *perm,
                               const int *input_stride, const int32_t *output_shape,
                               const int elem_bytes, const void *input_data,
                               void *output_data)
      {
#ifdef CFU_SOFTWARE_DEFINED
        return false; // software CFU has no transpose engine
#endif
        const int hw_rank = dims + (elem_bytes > 1 ? 1 : 0);
        if (dims < 1 || hw_rank > kNpuTransposeMaxRank)
          return false;
        if ((reinterpret_cast<uintptr_t>(input_data) |
             reinterpret_cast<uintptr_t>(output_data)) & 3)
          return false; // NPU bursts need word-aligned base addresses

        uint32_t total_bytes = static_cast<uint32_t>(elem_bytes);
        for (int d = 0; d < dims; ++d)
        {
          if (output_shape[d] <= 0)
            return false;
          total_bytes *= static_cast<uint32_t>(output_shape[d]);
          if (total_bytes > kNpuTransposeMaxBytes)
            return false;
        }

        // Input: write dirty lines back so the NPU reads current data.
        // Output: write back dirty lines (incl. neighbours sharing the first /
        // last line) now, and drop the stale copies after the NPU has written.
        CleanCacheRange(input_data, total_bytes);
        CleanCacheRange(output_data, total_bytes);

        cfu_op5(NPU_TR_CFG_ADDR, input_data, output_data);
        cfu_op5(NPU_TR_CFG_SIZE, hw_rank, total_bytes);
        for (int d = 0; d < dims; ++d)
        {
          cfu_op5(NPU_TR_CFG_DST_SHAPE, d, output_shape[d]);
          cfu_op5(NPU_TR_CFG_SRC_STRIDE, d, input_stride[perm[d]] * elem_bytes);
        }
        if (elem_bytes > 1)
        {
          cfu_op5(NPU_TR_CFG_DST_SHAPE, dims, elem_bytes);
          cfu_op5(NPU_TR_CFG_SRC_STRIDE, dims, 1);
        }
        const uint32_t status = cfu_op6(0, 0, 0); // 0 ok, 1 AXI error, 2 bad cfg

        InvalidateCacheRange(output_data, total_bytes);
        return status == 0;
      }

    } // namespace transpose_internal

    // Copies a tensor to an other buffer and permutes its dimensions.
    //
    // Note: template parameter N is not used anymore. It is kept for API
    // compatibility with TFLite micro.
    template <typename T, int N = kTransposeMaxDimensions>
    void Transpose(const TransposeParams &params, const RuntimeShape &input_shape,
                   const T *input_data, const RuntimeShape &output_shape,
                   T *output_data)
    {

      // perf reccord
      // TIMING START - DO NOT MODIFY OR MOVE.
      // --------------------------------------------------
      uint64_t start = perf_get_mcycle64();
      // --------------------------------------------------

      using transpose_internal::SetupTransposeStrides;
      using transpose_internal::TransposeImpl;
      using transpose_internal::TransposeStorageType;
      // Transpose kernel only does rearranging values not numeric evaluations on
      // each cell. It's safe to implement per size of scalar type and this trick
      // keeps the total code size in a reasonable range.
      using StorageType = typename TransposeStorageType<sizeof(T)>::type;
      const StorageType *const input_data_storage =
          reinterpret_cast<const StorageType *>(input_data);
      StorageType *const output_data_storage =
          reinterpret_cast<StorageType *>(output_data);

      const int dims = input_shape.DimensionsCount();
      std::array<int, kTransposeMaxDimensions> input_stride, output_stride;
      SetupTransposeStrides(input_stride, input_shape.DimsData(), dims);
      SetupTransposeStrides(output_stride, output_shape.DimsData(), dims);
      if (!transpose_internal::NpuTranspose(dims, &params.perm[0], input_stride.data(),
                                            output_shape.DimsData(), sizeof(T),
                                            input_data, output_data))
      {
        TransposeImpl(0, dims, &params.perm[0], input_data_storage,
                      input_stride.data(), output_data_storage, output_stride.data(),
                      output_shape.DimsData());
      }

      // record cycles
      // TIMING END AND STATISTICS - DO NOT MODIFY OR MOVE.
      // --------------------------------------------------
      perf_result.add_start(1);
      perf_result.add_result(1, perf_get_mcycle64() - start);
      // --------------------------------------------------
    }

  } // namespace reference_ops
} // namespace tflite

#endif // TENSORFLOW_LITE_KERNELS_INTERNAL_REFERENCE_TRANSPOSE_H_

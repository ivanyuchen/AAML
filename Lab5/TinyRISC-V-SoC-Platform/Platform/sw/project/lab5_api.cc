#include "lab5_api.h"
#include "cfu.h"
#define TEST_ALIGN 4096
uint32_t buf_A[TEST_ALIGN / 4] __attribute__((aligned(TEST_ALIGN))); // packed A
uint32_t buf_B[TEST_ALIGN / 4] __attribute__((aligned(TEST_ALIGN))); // packed B
int32_t buf_C[TEST_ALIGN / 4] __attribute__((aligned(TEST_ALIGN)));  // TPU result

// You can make your own design
// Here is a simple implementation.
// The functions convert matrices and vectors into a specific pattern
// and perform a general matrix-vector multiplication (GEMV) operation.
uint32_t *mat2pattern(const int8_t *mat, int M, int K)
{
    uint32_t *buf = buf_A; // static, page aligned (total_size <= MAX_WORDS)
    int pos = 0;
    for (int row = 0; row < M; row += 4)
    {
        for (int k = 0; k < K; k++)
        {
            // One column from four rows, PE0 in bits [31:24].
            uint32_t word = 0;
            for (int lane = 0; lane < 4; lane++)
            {
                if (row + lane < M)
                    word |= (uint32_t)(uint8_t)mat[(row + lane) * K + k]
                            << (24 - lane * 8);
            }

            buf[pos] = word;
            pos++;
        }
    }

    return buf;
}

uint32_t *vec2pattern(const int8_t *vec, int K)
{
    uint32_t *buf = buf_B; // static, page aligned (K <= MAX_WORDS)
    for (int k = 0; k < K; k++)
    {
        // TPU broadcasts only the highest byte to all four PEs.
        buf[k] = (uint32_t)(uint8_t)vec[k] << 24;
    }
    return buf;
}

void do_gemv(int M, int K, uint32_t *matA, uint32_t *matB, int32_t *matC)
{
    // Hardware drains MEM and writes back + invalidates D-cache before START.
    cfu_op7_hw(1, matA, matB);
    cfu_op7_hw(2, matC, 0);
    cfu_op7_hw(3, M, K);
    const uint32_t status = cfu_op7_hw(0, 0, 0);
    // START blocks until the final AXI write response has completed.
    if (status != 0)
        printf("GEMV failed: NPU status=%u\n", (unsigned)status);
}

// You don't have to follow the above design, you can implement your own design.
// Start your implementation here

// Don't modify this function, it will be called by the testbench
void do_gemv_test(int M, int K, const int8_t *matA, const int8_t *matB, int32_t *matC)
{
    // Validate before packing into the fixed-size buffers.
    if (M < 1 || M > 254 || K < 1 || K > 254 || ((M + 3) / 4) * K > 1024)
    {
        printf("GEMV unsupported size: M=%d K=%d\n", M, K);
        return;
    }
    uint32_t *pa = mat2pattern(matA, M, K);
    uint32_t *pb = vec2pattern(matB, K);
    do_gemv(M, K, pa, pb, matC);
    // Start your implementation here
}

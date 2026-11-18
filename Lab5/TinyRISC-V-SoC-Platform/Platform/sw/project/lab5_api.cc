#include "lab5_api.h"

#define TEST_ALIGN   4096
uint32_t buf_A[TEST_ALIGN / 4] __attribute__((aligned(TEST_ALIGN)));   // packed A
uint32_t buf_B[TEST_ALIGN / 4] __attribute__((aligned(TEST_ALIGN)));   // packed B
int32_t buf_C[TEST_ALIGN / 4] __attribute__((aligned(TEST_ALIGN)));   // TPU result

// You can make your own design
// Here is a simple implementation. 
// The functions convert matrices and vectors into a specific pattern 
// and perform a general matrix-vector multiplication (GEMV) operation.
// uint32_t* mat2pattern(int8_t* mat, int M, int N){
//     uint32_t* buf = buf_A;            // static, page aligned (total_size <= MAX_WORDS)
//     ...
//     return buf;
// }

// uint32_t* vec2pattern(int8_t* vec, int K){
//     uint32_t* buf = buf_B;            // static, page aligned (K <= MAX_WORDS)
//     ...
//     return buf;
// }

// void do_gemv(int M, int K, uint32_t* matA, uint32_t* matB, int32_t* matC){
//     assign K, M
//     laod mat A
//     laod vec B
//     run 
//     write result
// }

// You don't have to follow the above design, you can implement your own design.
// Start your implementation here

// Don't modify this function, it will be called by the testbench
void do_gemv_test(int M, int K, const int8_t* matA, const int8_t* matB, int32_t* matC){
    // uint32_t* pa = mat2pattern((int8_t*)matA, M, K);
    // uint32_t* pb = vec2pattern((int8_t*)matB, K);
    // do_gemv(M,K, pa, pb, matC);
    // Start your implementation here
}

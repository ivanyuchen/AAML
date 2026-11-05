#ifndef CONV_ADDR_ALIGNED_TEST_H_
#define CONV_ADDR_ALIGNED_TEST_H_

#include <cstdio>
#include <cstdint>

#include "tflm_patches/tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
#include "tensorflow/lite/kernels/internal/types.h"
#include "perf.h"

class ConvTestParam{
public:
    const char* test_name;
    int H, W, C, K, R, S;
    const int8_t* input, *golden;
    bool show_error;

    // Initialization
    ConvTestParam(
        const char* test_name_p, 
        int H_p, int W_p, int C_p, int K_p, int R_p, int S_p, bool show_error_p,  
        const int8_t* input_p, const int8_t* golden_p): 
    test_name(test_name_p), H(H_p), W(W_p), C(C_p), K(K_p), R(R_p), S(S_p), show_error(show_error_p), input(input_p), golden(golden_p){}
};

// Maximun Parameter Setting: 
// H = 16, W = 16, C = 16, K = 16, R = 3, S = 3
bool RunConvTest(ConvTestParam* conv_test_param, uint64_t* total_cycles);

void conv_address_aligned_test();

#endif
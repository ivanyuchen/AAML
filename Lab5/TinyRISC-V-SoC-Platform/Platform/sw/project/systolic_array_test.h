#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include "cfu.h"
#include "lab5_api.h"

#ifndef SYSTOLIC_ARRAY_TEST
#define SYSTOLIC_ARRAY_TEST

// A: ceil(M*K/4) <= 1024 words, B: ceil(K/4) <= 1024 words, C: M <= 1024 words
#define MAX_WORDS    1024          
#define C_SENTINEL   0x5A5A5A5A    
#define GUARD_WORDS  8
#define TPU_MAX_DIM  255           

static int32_t buf_golden[MAX_WORDS];
static int8_t sys_test_buf_A[MAX_WORDS * 4] __attribute__((aligned(32)));
static int8_t sys_test_buf_B[MAX_WORDS * 4] __attribute__((aligned(32)));

// testcase struct: A and B are raw row-major int8, passed to the TPU and the golden model as-is
struct Testcase{
    int idx;
    const char* name;
    int M;
    int K;
    int correct;
    const int8_t* matA;     // M x K, row-major int8, M*K bytes (zero-padded to a whole word)
    const int8_t* vecB;     // K x 1 int8, K bytes (zero-padded to a whole word)
    int32_t* result_C;      // M x 1 int32, M words
    int32_t* golden_C;      // M x 1 int32, M words
};

typedef struct {
    const char* name;
    int M, K, mode;
    const int8_t* A_init;   // full M*K elements (MODE_GIVEN only)
    const int8_t* B_init;   // full K elements   (MODE_GIVEN only)
} TestCfg;

void systolic_test();

#endif // SYSTOLIC_ARRAY_TEST
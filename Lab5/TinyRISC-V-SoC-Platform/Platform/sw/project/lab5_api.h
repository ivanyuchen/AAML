#ifndef LAB5_API_H
#define LAB5_API_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cfu.h"

extern uint32_t buf_A[];
extern uint32_t buf_B[];
extern int32_t buf_C[];

// This function structure only for reference, you can modify or add any function. 
// uint32_t* mat2pattern(int8_t* mat, int M, int N);
// uint32_t* vec2pattern(int8_t* vec, int K);
// void do_gemv(int M, int K, uint32_t* matA, uint32_t* matB, int32_t* matC);


// We would call this module to test you gemv implement. 
// Please make sure you have this function in "lab5_api.h"
void do_gemv_test(int M, int K, const int8_t* matA, const int8_t* matB, int32_t* matC);

#endif
#ifndef LAB5_API_H
#define LAB5_API_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cfu.h"

extern uint32_t buf_A[];
extern uint32_t buf_B[];
extern int32_t buf_C[];

// Packing helpers used by GEMV and Conv (A is row-major before packing).
uint32_t* mat2pattern(const int8_t* mat, int M, int K);
uint32_t* vec2pattern(const int8_t* vec, int K);
void do_gemv(int M, int K, uint32_t* matA, uint32_t* matB, int32_t* matC);

// We would call this module to test you gemv implement. 
// Please make sure you have this function in "lab5_api.h"
void do_gemv_test(int M, int K, const int8_t* matA, const int8_t* matB, int32_t* matC);

#endif
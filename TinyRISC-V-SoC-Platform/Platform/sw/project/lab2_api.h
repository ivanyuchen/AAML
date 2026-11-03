#ifndef LAB2_API_H
#define LAB2_API_H

#include<stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

extern int hw_simd_mac_cnt;
int32_t hw_simd_mac(
    int8_t *ptr1, int8_t *ptr2,
    int8_t input_offset, uint32_t N
);

#ifdef __cplusplus
}
#endif

#endif

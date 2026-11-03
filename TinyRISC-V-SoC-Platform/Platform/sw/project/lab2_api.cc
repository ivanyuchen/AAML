#include "lab2_api.h"

#include <stdio.h>
#include "cfu.h"
#include "cbo.h"

static void clean_cache_range(const void *ptr, uint32_t size)
{
    const uintptr_t cache_line_size = 32;
    uintptr_t current = reinterpret_cast<uintptr_t>(ptr) & ~(cache_line_size - 1);
    uintptr_t end = reinterpret_cast<uintptr_t>(ptr) + size;
    while (current < end)
    {
        cbo_clean(reinterpret_cast<const void *>(current));
        current += cache_line_size;
    }
}

static int32_t run_hw_mac(int8_t *ptr1, int8_t *ptr2, int32_t input_offset, uint32_t N)
{
    clean_cache_range(ptr1, N);
    clean_cache_range(ptr2, N);
    cfu_op3_hw(0, N, input_offset);
    uint32_t result = cfu_op3_hw(1, ptr1, ptr2);
    return static_cast<int32_t>(result);
}

int32_t hw_simd_mac(int8_t *ptr1, int8_t *ptr2, int8_t input_offset, uint32_t N)
{
    return run_hw_mac(ptr1, ptr2, static_cast<int32_t>(input_offset), N);
}

extern "C" int32_t hw_simd_mac_extended(
    int8_t *ptr1, int8_t *ptr2, int32_t input_offset, uint32_t N)
{
    return run_hw_mac(ptr1, ptr2, input_offset, N);
}

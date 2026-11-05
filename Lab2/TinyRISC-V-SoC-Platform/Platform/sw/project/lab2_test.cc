#include "lab2_test.h"
#include "lab2_api.h"

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

namespace{
// software reference
int32_t sw_simd_mac(
    int8_t const ptr1[], int8_t const ptr2[],
    int8_t input_offset, uint32_t N
){
    int32_t acc=0;
    for(uint32_t i=0;i<N;++i){
        const int32_t a=ptr1[i];
        const int32_t b=ptr2[i];
        acc+=(a+(int32_t)input_offset)*b;
    }
    return acc;
}

// data
int8_t mem1[260] __attribute__((aligned(4096)));
int8_t mem2[260] __attribute__((aligned(4096)));

// =============================================================
// helper functions
uint64_t random_i64(){
    static uint64_t seed=0xacacacacacacacac;
    seed = seed*6364136223846793005LL + 1;
    return seed;
}
void gen_random_data(int n){
    for(int i=0;i<n;++i){
        mem1[i]=(random_i64()>>56);
    }
    for(int i=0;i<n;++i){
        mem2[i]=(random_i64()>>56);
    }
}
struct TestCase{
    int8_t *ptr1;
    int8_t *ptr2;
    uint32_t N;
    int8_t input_offset;
    bool print_detail;
    bool print_buffer;
};
void print_test_data(TestCase &item){
    printf("buffer1:");
    for(uint32_t i=0;i<item.N;++i) printf(" %d", (int32_t)item.ptr1[i]);
    printf("\n");
    printf("buffer2:");
    for(uint32_t i=0;i<item.N;++i) printf(" %d", (int32_t)item.ptr2[i]);
    printf("\n");
}

// =============================================================
// gen testcase

int32_t gen_testcase_0(TestCase *ptr){
    const uint32_t N=4;
    const int8_t input_offset = 8;
    for(int i=0;i<4;++i) mem1[i]=i;
    for(int i=0;i<4;++i) mem2[i]=i;
    auto const ref = sw_simd_mac(
        mem1, mem2,
        input_offset, N
    );
    ptr->N = N;
    ptr->input_offset = input_offset;
    ptr->ptr1 = mem1;
    ptr->ptr2 = mem2;
    ptr->print_detail = true;
    ptr->print_buffer = true;
    return ref;
}
int32_t gen_testcase_1(TestCase *ptr){
    const uint32_t N=8;
    gen_random_data(N);
    int8_t input_offset = 11;
    auto const ref = sw_simd_mac(
        mem1, mem2,
        input_offset, N
    );
    ptr->N = N;
    ptr->input_offset = input_offset;
    ptr->ptr1 = mem1;
    ptr->ptr2 = mem2;
    ptr->print_detail = true;
    ptr->print_buffer = true;
    return ref;
}
int32_t gen_testcase_2(TestCase *ptr){
    const uint32_t N=24;
    gen_random_data(N);
    int8_t input_offset = -45;
    auto const ref = sw_simd_mac(
        mem1, mem2,
        input_offset, N
    );
    ptr->N = N;
    ptr->input_offset = input_offset;
    ptr->ptr1 = mem1;
    ptr->ptr2 = mem2;
    ptr->print_detail = true;
    ptr->print_buffer = true;
    return ref;
}

// random
int32_t gen_testcase_r(TestCase *ptr){
    const int32_t N = random_i64()%256 +1;
    gen_random_data(N+4);
    int8_t input_offset = random_i64()>>56;
    const int d1 = random_i64() %4;
    const int d2 = random_i64() %4;
    auto const ref = sw_simd_mac(
        &mem1[d1], &mem2[d2],
        input_offset, N
    );
    ptr->N = N;
    ptr->input_offset = input_offset;
    ptr->ptr1 = &mem1[d1];
    ptr->ptr2 = &mem2[d2];
    ptr->print_detail = false;
    ptr->print_buffer = false;
    return ref;
}

// =============================================================

int32_t (*gen_testcase_fp[100])(TestCase*);
int test_cnt;
void register_test(){
    test_cnt=0;
    gen_testcase_fp[test_cnt++]=gen_testcase_0;
    gen_testcase_fp[test_cnt++]=gen_testcase_1;
    gen_testcase_fp[test_cnt++]=gen_testcase_2;
}
int do_lab2_test(int test_id){
    if(test_id>=0) printf("testcase %d\n", test_id);
    TestCase test;
    int32_t ref;
    if(test_id<0) ref = gen_testcase_r(&test);
    else ref = gen_testcase_fp[test_id](&test);
    // print info
    if(test.print_detail){
        printf("N = %u\n", test.N);
        printf("input_offset = %d\n", test.input_offset);
    }
    if(test.print_buffer) print_test_data(test);
    // call hardware
    auto const ans = hw_simd_mac(
        test.ptr1, test.ptr2,
        test.input_offset, test.N
    );
    // check result
    if(test.print_detail){
        printf(" ref ans = %d\n", ref);
        printf("your ans = %d\n", ans);
    }
    bool is_err = ans != ref;
    if(test_id>=0){
        printf(is_err ? "WA\n": "AC\n");
        printf("================\n");
    }
    return is_err;
}

} // end of namespace

#ifdef __cplusplus
extern "C" {
#endif
void do_lab2_set_test(){
    register_test();
    printf("start lab2 set tests\n");
    int pass_cnt=0;
    for(int i=0;i<test_cnt;++i){
        if(do_lab2_test(i)==0) ++pass_cnt;
    }
    printf("Pass %d/%d\n", pass_cnt, test_cnt);
}
void do_lab2_random_test(){
    printf("start lab2 random test\n");
    const int T=100;
    int pass_cnt=0;
    for(int i=0;i<T;++i){
        if(do_lab2_test(-1)==0) ++pass_cnt;
    }
    printf("Pass %d/%d\n", pass_cnt, T);
}
#ifdef __cplusplus
}
#endif

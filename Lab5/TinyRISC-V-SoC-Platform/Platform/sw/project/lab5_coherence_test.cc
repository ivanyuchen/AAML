#include "lab5_api.h"

namespace {
alignas(32) int8_t input_a[4096];
alignas(32) int8_t input_b[256];
alignas(32) int32_t output[264];
int32_t golden[254];
alignas(32) volatile uint8_t eviction[96 * 1024];
uint32_t rng = 0x38ab721u;
const int32_t sentinel = 0x5a5a5a5a;

int8_t next_value() {
    rng = rng * 1664525u + 1013904223u;
    return static_cast<int8_t>(rng >> 24);
}

bool run_case(int M, int K, bool dirty_c, bool evict_after) {
    for (int i = 0; i < M * K; ++i) input_a[i] = next_value();
    for (int k = 0; k < K; ++k) input_b[k] = next_value();
    for (int m = 0; m < M; ++m) {
        int32_t sum = 0;
        for (int k = 0; k < K; ++k)
            sum += static_cast<int32_t>(input_a[m * K + k]) * input_b[k];
        golden[m] = sum;
    }
    if (dirty_c) {
        for (int i = 0; i < 264; ++i) output[i] = sentinel;
    }
    // C starts one word into the line: unrelated guard data shares that line.
    // In the clean-C case these reads prime old output without dirtying it.
    volatile int32_t* observed = output;
    volatile int32_t prime = 0;
    for (int i = 0; i <= M; ++i) prime = observed[i];
    (void)prime;
    do_gemv_test(M, K, input_a, input_b, output + 1);
    if (evict_after) {
        for (unsigned i = 0; i < sizeof(eviction); i += 32)
            eviction[i] = static_cast<uint8_t>(i >> 5);
    }
    for (int m = 0; m < M; ++m) {
        if (observed[m + 1] != golden[m]) {
            printf("[FAIL] coherence C[%d]: expected %ld got %ld\n", m,
                   static_cast<long>(golden[m]), static_cast<long>(observed[m + 1]));
            return false;
        }
    }
    if (observed[0] != sentinel || observed[M + 1] != sentinel) {
        printf("[FAIL] coherence shared-line guard overwritten\n");
        return false;
    }
    return true;
}
}

void run_lab5_coherence_test() {
    unsigned passed = 0;
    // Alternating dirty/clean old C across repeated operations with new A/B.
    for (int i = 0; i < 8; ++i) {
        const bool ok = run_case(5, 5, (i % 2) == 0, (i % 3) == 0);
        printf("[%s] coherence repeated %d: %s C, eviction=%d\n",
               ok ? "PASS" : "FAIL", i, (i % 2) == 0 ? "dirty" : "clean",
               (i % 3) == 0);
        if (ok) ++passed;
    }
    const int shapes[][2] = {{254, 16}, {16, 254}, {64, 64}, {1, 1}};
    for (unsigned i = 0; i < 4; ++i) {
        const bool ok = run_case(shapes[i][0], shapes[i][1], true, true);
        printf("[%s] coherence M=%d K=%d\n", ok ? "PASS" : "FAIL",
               shapes[i][0], shapes[i][1]);
        if (ok) ++passed;
    }
    printf("Coherence tests: %u/12 passed (no software CBO)\n", passed);
}

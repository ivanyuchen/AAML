#include "systolic_array_test.h"

static inline int guard_words(int M) {
    int g = MAX_WORDS - M;
    return g > GUARD_WORDS ? GUARD_WORDS : (g < 0 ? 0 : g);
}

static inline int words_of(int bytes) { return (bytes + 3) / 4; }

static inline int verify(Testcase* t) {
    int ok = true;
    for (int i = 0; i < t->M; i++) {
        if (t->result_C[i] != t->golden_C[i]) {
            printf("    C[%d]: expected %d, got %d\n", i, t->golden_C[i], t->result_C[i]);
            ok = false;
            break;
        }
    }
    const int g = guard_words(t->M);
    for (int i = t->M; i < t->M + g; i++) {
        if (t->result_C[i] != (int32_t)C_SENTINEL) {
            printf("    guard C[%d] overwritten: 0x%08x (TPU wrote beyond M)\n",
                   i, (unsigned)t->result_C[i]);
            ok = false;
            break;
        }
    }
    return ok;
}

// golden uses exactly the same buffers that are handed to the hardware
static inline void gemv_golden(Testcase* t) {
    for (int i = 0; i < t->M; i++) {
        int32_t sum = 0;
        for (int j = 0; j < t->K; j++)
            sum += (int32_t)t->matA[i * t->K + j] * (int32_t)t->vecB[j];
        t->golden_C[i] = sum;
    }
}

// ------------------------------------------------------------------------------------------------
// Testcase setup
// ------------------------------------------------------------------------------------------------
enum { MODE_GIVEN = 0, MODE_RAMP = 1, MODE_RANDOM = 2, MODE_MIN = 3 };

static uint32_t lcg_state = 12345u;
static int8_t rnd8(void) {
    lcg_state = lcg_state * 1664525u + 1013904223u;
    return (int8_t)(lcg_state >> 24);
}

// Whole matrix A (M x K) and whole vector B (K) are filled as raw int8 and used as-is.
static inline int setup_testcase(Testcase* t, int idx, const char* name, int M, int K, int mode,
                          const int8_t* A_init, const int8_t* B_init) {
    t->idx     = idx;
    t->name    = name;
    t->correct = false;
    t->M       = M;
    t->K       = K;

    if (M < 1 || K < 1 || M > TPU_MAX_DIM || K > TPU_MAX_DIM ||
        M > MAX_WORDS || words_of(M * K) > MAX_WORDS || words_of(K) > MAX_WORDS) {
        printf("    unsupported size M=%d K=%d\n", M, K);
        return false;
    }
    if (mode == MODE_GIVEN && (!A_init || !B_init)) {
        printf("    MODE_GIVEN needs full A (M*K) and B (K)\n");
        return false;
    }

    // zero the padding so the last partial word is deterministic
    for (int i = 0; i < words_of(M * K) * 4; i++) sys_test_buf_A[i] = 0;
    for (int i = 0; i < words_of(K) * 4;     i++) sys_test_buf_B[i] = 0;

    for (int i = 0; i < M * K; i++) {
        switch (mode) {
            case MODE_GIVEN:  sys_test_buf_A[i] = A_init[i];         break;
            case MODE_RAMP:   sys_test_buf_A[i] = (int8_t)(i - 12);  break;
            case MODE_RANDOM: sys_test_buf_A[i] = rnd8();            break;
            default:          sys_test_buf_A[i] = -128;              break;
        }
    }
    for (int j = 0; j < K; j++) {
        switch (mode) {
            case MODE_GIVEN:  sys_test_buf_B[j] = B_init[j];         break;
            case MODE_RAMP:   sys_test_buf_B[j] = (int8_t)(j + 1);   break;
            case MODE_RANDOM: sys_test_buf_B[j] = rnd8();            break;
            default:          sys_test_buf_B[j] = -128;              break;
        }
    }

    t->matA     = sys_test_buf_A;
    t->vecB     = sys_test_buf_B;
    t->result_C = buf_C;
    t->golden_C = buf_golden;
    gemv_golden(t);
    return true;
}

// ------------------------------------------------------------------------------------------------
// Test table
// ------------------------------------------------------------------------------------------------
static const int8_t matA_temp[16] = {
     1,   3,   7,  15,
    -1, -20,  16,  43,
     2,  18,  -5,  31,
    27, -34,  91,  10
};
static const int8_t vecB[4] = {4, 1, 4, 7};      // exactly K = 4 elements

static const TestCfg cfgs[] = {
    //  name                 M   K   mode          A_init      B_init
    { "given 4x4",           4,  4,   MODE_GIVEN,   matA_temp,  vecB },
    { "8x8 random",          8,  8,   MODE_RANDOM,  0,          0    },
    { "16x16 random",       16, 16,   MODE_RANDOM,  0,          0    },
    { "3x3 random",          3,  3,   MODE_RANDOM,  0,          0    },
    { "5x5 random",          5,  5,   MODE_RANDOM,  0,          0    },
    { "8x8 all -128",        8,  8,   MODE_MIN,     0,          0    },
    { "32x16 random",       32, 16,   MODE_RANDOM,  0,          0    },
    { "24x35 random",       24, 35,   MODE_RANDOM,  0,          0    },
    { "64x1 random",        64,  1,   MODE_RANDOM,  0,          0    },
    { "27x31 random",       27, 31,   MODE_RANDOM,  0,          0    },
    { "41x37 random",       41, 37,   MODE_RANDOM,  0,          0    },
};

void systolic_test(){
    int total_test = (int)(sizeof(cfgs) / sizeof(cfgs[0]));
    int pass = 0;

    printf("---- Systolic Test Start ----\n");

    for (int n = 0; n < total_test; n++) {
        Testcase t;
        const TestCfg* c = &cfgs[n];

        if (!setup_testcase(&t, n, c->name, c->M, c->K, c->mode, c->A_init, c->B_init)) {
            printf("[FAIL] %d, %s: bad testcase setup.\n", n, c->name);
            continue;
        }

        const int total = t.M + guard_words(t.M);
        for (int i = 0; i < total; i++) t.result_C[i] = (int32_t)C_SENTINEL;

        do_gemv_test(t.M, t.K, t.matA, t.vecB, t.result_C);

        t.correct = verify(&t);
        if (t.correct) {
            pass++;
            printf("[PASS] %d, %s: corrected result. (M=%d K=%d)\n", t.idx, t.name, t.M, t.K);
        } else {
            printf("[FAIL] %d, %s: wrong result. (M=%d K=%d)\n", t.idx, t.name, t.M, t.K);
        }
    }

    printf("Result : Pass %d / %d\n", pass, total_test);
}
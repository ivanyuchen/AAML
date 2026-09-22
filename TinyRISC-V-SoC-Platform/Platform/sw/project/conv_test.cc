#include "conv_test.h"
#include "conv_test_data.h"

bool RunConvTest(ConvTestParam* conv_test_param, uint64_t* total_cycles){

    int H = conv_test_param->H;
    int W = conv_test_param->W;
    int C = conv_test_param->C;
    int K = conv_test_param->K;
    int R = conv_test_param->R;
    int S = conv_test_param->S;    

    // Allocate 4-byte aligned buffers using alignas
    alignas(4) static int8_t input_data[16 * 16 * 16];
    alignas(4) static int8_t filter_data[16 * 3 * 3 * 16];
    alignas(4) static int32_t bias_data[16];
    alignas(4) static int32_t output_multiplier[16];
    alignas(4) static int32_t output_shift[16];
    alignas(4) static int8_t cfu_output[16 * 16 * 16];

    // Initialize with test pattern
    memcpy(input_data, conv_test_param->input, H*W*C);

    for (size_t i = 0; i < sizeof(filter_data); ++i) filter_data[i] = (i % 16) - 8;
    for (int i = 0; i < K; ++i) {
        bias_data[i] = i * 7 * ((i%3)?1:-1);
        output_multiplier[i] = 1073741824;
        output_shift[i] = -1;
    }

    // Define Shapes using TensorFlow Lite Micro RuntimeShape methods
    tflite::RuntimeShape input_shape(4);
    input_shape.SetDim(0, 1);
    input_shape.SetDim(1, H);
    input_shape.SetDim(2, W);
    input_shape.SetDim(3, C);

    tflite::RuntimeShape filter_shape(4);
    filter_shape.SetDim(0, K);
    filter_shape.SetDim(1, R);
    filter_shape.SetDim(2, S);
    filter_shape.SetDim(3, C);

    tflite::RuntimeShape bias_shape(1);
    bias_shape.SetDim(0, K);

    tflite::RuntimeShape output_shape(4);
    output_shape.SetDim(0, 1);
    output_shape.SetDim(1, H);
    output_shape.SetDim(2, W);
    output_shape.SetDim(3, K);

    tflite::ConvParams params;
    params.input_offset = 3;
    params.output_offset = -2;
    params.stride_width = 1;
    params.stride_height = 1;
    params.dilation_width_factor = 1;
    params.dilation_height_factor = 1;
    params.padding_values.width = 0;
    params.padding_values.height = 0;
    params.quantized_activation_min = -128;
    params.quantized_activation_max = 127;

    // Run ConvPerChannel
    uint64_t start_cycles = perf_get_mcycle64();

    tflite::reference_integer_ops::ConvPerChannel(
        params, output_multiplier, output_shift,
        input_shape, input_data, filter_shape, filter_data,
        bias_shape, bias_data, output_shape, cfu_output
    );

    uint64_t duration = perf_get_mcycle64() - start_cycles;

    // Functional Correctness Check
    size_t total_outputs = output_shape.FlatSize();
    int errors = 0;
    for (size_t i = 0; i < total_outputs; ++i) {
        if (cfu_output[i] != conv_test_param->golden[i]) {
            if(conv_test_param->show_error)
                printf("[FAIL] Mismatch at index %zu: CFU = %d, Golden = %d\n", i, cfu_output[i], conv_test_param->golden[i]);
            errors++;
        }
    }

    if (errors == 0) {
        printf("[PASS] %s, Output Correct, Cycles=", conv_test_param->test_name);
        perf_print_cycles(duration);
        printf("\n");
        *total_cycles += duration;
        return true;
    } else {
        printf("[FAIL] Total Mismatches: %d / %zu\n", errors, total_outputs);
        return false;
    }
}

void conv_address_aligned_test() {
    bool all_passed = true;
    uint64_t total_cycles = 0;

    int testcase_n = 3;
    ConvTestParam testcase[] = {
        ConvTestParam("Testcase1", 4, 4, 8, 8, 1, 1, true,Test1InputData, Test1GoldenData),
        ConvTestParam("Testcase2", 8, 8, 16, 16, 1, 1, false,Test2InputData, Test2GoldenData),
        ConvTestParam("Testcase3", 16, 16, 16, 16, 1, 1, false,Test3InputData, Test3GoldenData)
    };

    // Basic Testcase
    for(int i = 0; i < testcase_n; i++){    
        all_passed &= RunConvTest(&testcase[i], &total_cycles);
    }

    if(all_passed){
        printf("Basic Conv Test: (    ");
        perf_print_cycles(total_cycles);
        printf(") Cycles total\n");
    }
}
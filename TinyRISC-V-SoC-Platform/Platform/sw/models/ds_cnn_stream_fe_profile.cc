#include "model_profile.h"

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "label/label0_board.h"
#include "label/label1_board.h"
#include "platform_config.h"

namespace {

struct AudioSample {
  const char* name;
  const float* data;
  size_t element_count;
  int expected_label;
  const uint32_t* golden_output_bits;
};

const uint32_t kLabel0GoldenOutput[] = {
  0x418d80ea,0xc099a1e8,0xc0c20fe2,0xc0815fec,
  0xc0ca25e1,0xc10d80ea,0xc0015fec,0xc0d23be0,
  0xc0815fec,0xc0a9cde6,0xc125c2e6,0xc099a1e8,
};

const uint32_t kLabel1GoldenOutput[] = {
  0xc1c41562,0x4129cde6,0xc12dd8e5,0xc0da51de,
  0xbe815fec,0xc0f293da,0x3f015fec,0xc0118bea,
  0xc08975eb,0xc0d23be0,0xc0da51de,0xc1056aeb,
};

const size_t kGoldenOutputElementCount =
    sizeof(kLabel0GoldenOutput) / sizeof(kLabel0GoldenOutput[0]);

const AudioSample kSamples[] = {
    {"label0", label0_data, sizeof(label0_data) / sizeof(label0_data[0]), 0,
     kLabel0GoldenOutput},
    {"label1", label1_data, sizeof(label1_data) / sizeof(label1_data[0]), 1,
     kLabel1GoldenOutput},
};

const size_t kSampleCount = sizeof(kSamples) / sizeof(kSamples[0]);

void clear_input(TfLiteTensor* input) {
  memset(input->data.raw, 0, input->bytes);
}

void ds_cnn_prepare_input(TfLiteTensor* input, size_t sample_index) {
  if (input == 0 || sample_index >= kSampleCount) {
    return;
  }

  const AudioSample& sample = kSamples[sample_index];
  size_t input_elements = 0;
  if (input->type == kTfLiteFloat32) {
    input_elements = input->bytes / sizeof(float);
  } else if (input->type == kTfLiteInt8) {
    input_elements = input->bytes;
  } else {
    printf("Input %s: unsupported tensor type=%d; using zeros.\n", sample.name,
           input->type);
    clear_input(input);
    return;
  }

  printf("Input: %s, elements=%u, bytes=%u, type=%d\n", sample.name,
         (unsigned)sample.element_count, (unsigned)input->bytes, input->type);
  if (input_elements != sample.element_count) {
    printf("Input size mismatch: tensor=%u elements, fixture=%u; using zeros.\n",
           (unsigned)input_elements, (unsigned)sample.element_count);
    clear_input(input);
    return;
  }

  if (input->type == kTfLiteFloat32) {
    memcpy(input->data.f, sample.data, input->bytes);
    return;
  }

  const float scale = input->params.scale;
  const int32_t zero_point = input->params.zero_point;
  if (scale <= 0.0f) {
    printf("Input %s: invalid quantization scale; using zeros.\n", sample.name);
    clear_input(input);
    return;
  }

  for (size_t i = 0; i < input_elements; ++i) {
    int32_t quantized = (int32_t)(sample.data[i] / scale) + zero_point;
    if (quantized > 127) quantized = 127;
    if (quantized < -128) quantized = -128;
    input->data.int8[i] = (int8_t)quantized;
  }
}

void ds_cnn_verify_output(const TfLiteTensor* output, size_t sample_index) {
  if (output == 0 || sample_index >= kSampleCount) {
    return;
  }

  const AudioSample& sample = kSamples[sample_index];
  if (output->type != kTfLiteFloat32) {
    printf("Output %s: golden data requires float32, got type=%d. [FAIL]\n",
           sample.name, output->type);
    return;
  }

  const size_t output_elements = output->bytes / sizeof(float);
  if (output_elements != kGoldenOutputElementCount) {
    printf("Output %s: tensor=%u elements, golden=%u. [FAIL]\n", sample.name,
           (unsigned)output_elements, (unsigned)kGoldenOutputElementCount);
    return;
  }

  int predicted_label = 0;
  int error_count = 0;
  for (size_t i = 0; i < output_elements; ++i) {
    if (output->data.f[i] > output->data.f[predicted_label]) {
      predicted_label = (int)i;
    }

    uint32_t actual_bits = 0;
    memcpy(&actual_bits, &output->data.f[i], sizeof(actual_bits));
    const uint32_t golden_bits = sample.golden_output_bits[i];
    const bool matches = actual_bits == golden_bits;
    printf("Idx %u: Actual=0x%08x, Golden=0x%08x [%s]\n", (unsigned)i,
           (unsigned)actual_bits, (unsigned)golden_bits,
           matches ? "PASS" : "FAIL");
    if (!matches) {
      ++error_count;
    }
  }

  printf("Prediction: %d, expected: %d [%s]\n", predicted_label,
         sample.expected_label,
         predicted_label == sample.expected_label ? "PASS" : "FAIL");
  if (error_count == 0) {
    printf("[Status] %s: ALL %u GOLDEN OUTPUTS PASS.\n", sample.name,
           (unsigned)output_elements);
  } else {
    printf("[Status] %s: FAIL with %d output mismatches.\n", sample.name,
           error_count);
  }
}

}  // namespace

const ModelProfile* model_profile_get(void) {
  static const ModelProfile kProfile = {
      "ds_cnn_stream_fe",
      "board audio fixtures",
      "golden output and argmax class",
      ds_cnn_prepare_input,
      ds_cnn_verify_output,
      0,
      0,
      0,
      0,
      0,
      kSampleCount,
  };
  return &kProfile;
}

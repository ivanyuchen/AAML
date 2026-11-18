#include "tflm_ops.h"
#include "tensorflow/lite/micro/kernels/micro_ops.h"

void tflm_register_project_ops(ProjectOpResolver* resolver) {
  resolver->AddAveragePool2D();
  resolver->AddConv2D();
  resolver->AddDepthwiseConv2D();
  resolver->AddFullyConnected();
  resolver->AddMaxPool2D();
  resolver->AddRelu();
  resolver->AddRelu6();
  resolver->AddReshape();
  resolver->AddSoftmax();
  resolver->AddAudio_Spectrogram();
  resolver->AddQuantize();
  resolver->AddDequantize();
  resolver->AddMFCC();
  resolver->AddMul();
  resolver->AddLogistic();
  resolver->AddAdd();
  resolver->AddSub();
  resolver->AddMean();
  resolver->AddTranspose();
  resolver->AddConcatenation();
  resolver->AddPad();
  resolver->AddStridedSlice();
  resolver->AddSlice();
  resolver->AddDiv();
  resolver->AddSqrt();
  resolver->AddRsqrt();
  resolver->AddBatchMatMul();
}

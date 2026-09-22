#include "model_profile.h"
#include<stdio.h>
#include "platform_config.h"

#include "models/label/label1_board.h"

static void ds_cnn_prepare_input(TfLiteTensor* input, size_t index)
{
    if (input == nullptr)
        return;

    printf("input bytes=%d type=%d\n",
           input->bytes,
           input->type);

    if (input->type == kTfLiteFloat32)
    {
        float* dst = input->data.f;

        int count = input->bytes / sizeof(float);

        for(int i=0;i<count;i++)
        {
            dst[i] = label1_data[i];
        }
    }

    else if(input->type == kTfLiteInt8)
    {
        int8_t* dst = input->data.int8;
        int count = input->bytes;

        float scale = input->params.scale;
        int32_t zero_point = input->params.zero_point;

        for(int i = 0; i < count; i++)
        {
            int32_t q = (int32_t)(label1_data[i] / scale) + zero_point;

            if(q > 127)  q = 127;
            if(q < -128) q = -128;

            dst[i] = (int8_t)q;
        }
    }
}


static void ds_cnn_verify_output(const TfLiteTensor* output, size_t index)
{
    (void)output;
}

const ModelProfile* model_profile_get(void)
{
    static const ModelProfile kProfile = {
        "ds_cnn_stream_fe",
        "label1 board audio input",
        "verification skipped",
        ds_cnn_prepare_input,
        ds_cnn_verify_output,
        0,
        0,
        0,
        0,
        MODEL_TOLERANCE,
        1
    };


    return &kProfile;
}
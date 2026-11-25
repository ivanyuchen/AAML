// Host-only regression test; std::vector is not part of the SoC firmware.
#include <cassert>
#include <vector>
#include <cstdio>
#include "tensorflow/lite/kernels/internal/reference/integer_ops/conv.h"
#include "conv_cpu_reference.h"
PerfResult perf_result;
PerfResult::PerfResult() {}
void PerfResult::add_start(int) {}
void PerfResult::add_result(int,uint64_t) {}
static uint32_t *a,*b;
static int32_t *c;
static int m,k,phase=0,calls=0;
uint32_t software_cfu_raw(uint32_t f3,uint32_t f7,CfuWord x,CfuWord y) {
  assert(f3==7);
  switch(f7) {
    case 1:assert(phase==0);a=(uint32_t*)x;b=(uint32_t*)y;phase=1;break;
    case 2:assert(phase==1);c=(int32_t*)x;phase=2;break;
    case 3:assert(phase==2);m=x;k=y;assert(m>=1 && m<=254 && k>=1 && k<=254);phase=3;break;
    case 0:
      assert(phase==3);
      for(int row=0;row<m;row++) {
        int32_t sum=0;
        for(int col=0;col<k;col++) {
          int8_t av=a[(row/4)*k+col]>>(24-8*(row%4));
          int8_t bv=b[col]>>24;
          sum+=(int32_t)av*bv;
        }
        c[row]=sum;
      }
      phase=0;calls++;break;
    default:assert(false);
  }
  return 0;
}
static unsigned rng=0x987161u;
static int rnd() {rng=1664525u*rng+1013904223u;return rng>>24;}
static void check(int batch,int h,int w,int ic,int oc,int fh,int fw,int stride,int dilation,int pad,int groups,int offset,bool bias) {
  int oh=(h+2*pad-dilation*(fh-1)-1)/stride+1;
  int ow=(w+2*pad-dilation*(fw-1)-1)/stride+1;
  if(oh<1 || ow<1)return;
  int32_t id[]={batch,h,w,ic},fd[]={oc,fh,fw,ic/groups},od[]={batch,oh,ow,oc},bd[]={oc};
  tflite::RuntimeShape is(4,id),fs(4,fd),os(4,od),bs(1,bd);
  std::vector<int8_t> input(is.FlatSize()),filter(fs.FlatSize()),out(os.FlatSize()),expected(os.FlatSize());
  std::vector<int32_t> biases(oc),mult(oc),shift(oc);
  for(auto& v:input)v=(int8_t)rnd();
  for(auto& v:filter)v=(int8_t)(rnd()%31-15);
  for(int i=0;i<oc;i++){biases[i]=rnd()*7-500;mult[i]=1073741824+rnd()*1024;shift[i]=-9+(i%3);}
  tflite::ConvParams p={};p.input_offset=offset;p.output_offset=-3;
  p.stride_width=p.stride_height=stride;p.dilation_width_factor=p.dilation_height_factor=dilation;
  p.padding_values.width=p.padding_values.height=pad;
  p.quantized_activation_min=-110;p.quantized_activation_max=115;
  const int32_t* biasptr=bias?biases.data():nullptr;
  tflite::reference_integer_ops::ConvPerChannel(p,mult.data(),shift.data(),is,input.data(),fs,filter.data(),bs,biasptr,os,out.data());
  tflite::cpu_conv_reference::ConvPerChannel(p,mult.data(),shift.data(),is,input.data(),fs,filter.data(),bs,biasptr,os,expected.data());
  for(unsigned i=0;i<out.size();i++)if(out[i]!=expected[i]){
    printf("FAIL batch=%d IC=%d OC=%d F=%dx%d stride=%d dil=%d pad=%d groups=%d off=%d index=%u got=%d expected=%d\n",batch,ic,oc,fh,fw,stride,dilation,pad,groups,offset,i,out[i],expected[i]);
    assert(false);
  }
}
int main() {
  int cases=0;
  for(int ic:{1,3,32,128,255})for(int oc:{1,3,4,5,8})for(int off:{0,128,-127}){
    check(1,5,6,ic,oc,3,3,1,1,1,1,off,true);cases++;
  }
  for(int stride:{1,2})for(int dil:{1,2})for(int pad:{0,1,2}){
    check(2,7,8,6,10,2,3,stride,dil,pad,2,37,false);cases++;
  }
  check(1,3,4,300,7,1,1,1,1,0,1,128,true);cases++;
  for(int oc:{65,251,252,253,254,255,320})for(int ic:{1,16,80,255}){
    check(1,2,3,ic,oc,1,1,1,1,0,1,128,true);cases++;
  }
  check(1,1,1,600,512,1,1,1,1,0,1,37,true);cases++;
  check(1,2,2,3,5,1,1,1,1,0,1,129,true);cases++;
  printf("PASS %d Conv cases exactly match original CPU reference; %d GEMV calls, no sanitizer errors\n",cases,calls);
}

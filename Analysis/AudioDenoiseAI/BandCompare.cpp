#include "DenoiseInference.hpp"
#include "CDSPResampler.h"
#include <memory>
#define private public
#include "AudioDenoiseCore.hpp"
#undef private
#include <cstdio>
int main(){dayu::AudioDenoiseCore::LR low,high;dayu::AudioDenoiseCore::Biquad phase;low.prepare(64000,500);high.prepare(64000,4000);phase.prepareAllpass(64000,4000);float ref[3][16384];for(int b=0;b<3;++b){char path[128];snprintf(path,sizeof path,"Analysis/AudioDenoiseAI/reference-band-%d.f32",b);FILE*f=fopen(path,"rb");if(!f||fread(ref[b],4,16384,f)!=16384)return 1;fclose(f);}float error[3]={};for(int i=0;i<16384;++i){auto l=low.process(i==0?1:0);auto h=high.process(l[1]);float out[3]={phase.process(l[0]),h[0],h[1]};for(int b=0;b<3;++b)error[b]=std::max(error[b],std::abs(out[b]-ref[b][i]));}printf("{\"sampleCountPerBand\":16384,\"maxErrors\":[%.9g,%.9g,%.9g]}\n",error[0],error[1],error[2]);return error[0]==0&&error[1]==0&&error[2]==0?0:2;}

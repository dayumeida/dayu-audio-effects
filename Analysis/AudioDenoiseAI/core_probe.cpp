#include "AudioDenoiseCore.hpp"
#include <memory>
#include <cstdio>
#include <chrono>
int main(int argc,char**argv){auto c=std::make_unique<dayu::AudioDenoiseCore>();if(!c->loadModel(argv[1]))return 1;c->prepare(48000);float l[512],r[512],o[512],p[512];float*in[]={l,r},*out[]={o,p};auto begin=std::chrono::steady_clock::now();float peak=0;double worst=0;for(int k=0;k<480000;k+=512){for(int i=0;i<512;++i){l[i]=r[i]=.2*std::sin((k+i)*.02);}auto a=std::chrono::steady_clock::now();c->process(in,out,2,512);worst=std::max(worst,std::chrono::duration<double>(std::chrono::steady_clock::now()-a).count());for(float x:o){if(!std::isfinite(x))return 2;peak=std::max(peak,std::abs(x));}}printf("peak %.9g; delay %u; elapsed %.6f; worst block %.6fms\n",peak,c->latencyFrames(),std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count(),worst*1000);}

#include "DenoiseInference.hpp"
#include <cstdio>
#include <chrono>
int main(int argc,char**argv){dayu_denoise::Inference e;if(argc<2||!e.prepare(argv[1]))return 1;float input[16384];FILE*f=fopen("test-input.f32","rb");fread(input,4,16384,f);fclose(f);double total=0,worst=0;int steps=0;
for(int run=0;run<11;++run){e.begin(input);auto begin=std::chrono::steady_clock::now();while(e.busy()){auto a=std::chrono::steady_clock::now();e.step();auto b=std::chrono::steady_clock::now();if(run)worst=std::max(worst,std::chrono::duration<double>(b-a).count());if(run==1)++steps;}auto end=std::chrono::steady_clock::now();if(run)total+=std::chrono::duration<double>(end-begin).count();}
for(int i=0;i<20;++i){char name[64];snprintf(name,sizeof(name),"test-native-layer-%d.f32",i);f=fopen(name,"wb");fwrite(e.activation(i),4,dayu_denoise::layers[i].outputs*dayu_denoise::layers[i].outputLength,f);fclose(f);}
f=fopen("test-native.f32","wb");fwrite(e.output(),4,16384,f);fclose(f);printf("{\"inferenceMeanMS\":%.6f,\"worstTileMS\":%.6f,\"tiles\":%d}\n",total*100,worst*1000,steps);
}

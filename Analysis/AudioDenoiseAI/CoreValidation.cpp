#include "AudioDenoiseCore.hpp"
#include <dlfcn.h>
#include <cstdio>
#include <chrono>
#include <memory>
#include <vector>
#include <limits>
#include <thread>
#include <atomic>
#include <pthread.h>
using Logger=void(*)(uint32_t,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uint32_t);
static uint64_t allocationCalls=0;static std::atomic<uintptr_t>trackedThread{0};
static void logAlloc(uint32_t type,uintptr_t,uintptr_t,uintptr_t,uintptr_t,uint32_t){if(trackedThread.load(std::memory_order_relaxed)==reinterpret_cast<uintptr_t>(pthread_self())&&(type&2))++allocationCalls;}
static float sample(uint64_t n,int c){if(n==12345)return std::numeric_limits<float>::quiet_NaN();if(n==34567)return std::numeric_limits<float>::infinity();return float(.1*std::sin(double(n)*.0197)+.03*std::sin(double(n)*.0471))*(c?.8f:1.f);}
int main(int argc,char**argv){auto slot=(Logger*)dlsym(RTLD_DEFAULT,"malloc_logger");if(argc>2)slot=nullptr;Logger saved=slot?*slot:nullptr;if(slot)*slot=logAlloc;bool pass=true;
for(double rate:{32000.,44100.,48000.,96000.}){const uint64_t total=uint64_t(rate*2.);std::vector<float>baseline;
 for(uint32_t block:{512u,1u,17u,64u,128u,16384u}){auto core=std::make_unique<dayu::AudioDenoiseCore>();if(!core->loadModel(argv[1]))return 1;core->prepare(rate);core->rampParameter(2,100,301);core->setParameter(4,50);std::vector<float>left(block),right(block),out0(block),out1(block),result(total);float*in[]={left.data(),right.data()},*out[]={out0.data(),out1.data()};double worst=0,sum=0;uint64_t count=0;allocationCalls=0;
 std::thread render([&]{for(uint64_t start=0;start<total;start+=block){const uint32_t n=uint32_t(std::min<uint64_t>(block,total-start));for(uint32_t i=0;i<n;++i){left[i]=sample(start+i,0);right[i]=sample(start+i,1);}trackedThread.store(reinterpret_cast<uintptr_t>(pthread_self()),std::memory_order_relaxed);auto a=std::chrono::steady_clock::now();core->process(in,out,2,n);auto b=std::chrono::steady_clock::now();trackedThread.store(0,std::memory_order_relaxed);const double elapsed=std::chrono::duration<double>(b-a).count();sum+=elapsed;worst=std::max(worst,elapsed);++count;std::copy(out0.begin(),out0.begin()+n,result.begin()+start);}});render.join();
 float difference=0;bool finite=true;for(uint64_t i=0;i<total;++i){finite&=std::isfinite(result[i]);if(!baseline.empty())difference=std::max(difference,std::abs(result[i]-baseline[i]));}if(baseline.empty())baseline=result;pass&=finite&&difference==0&&allocationCalls==0;
 printf("{\"rate\":%.0f,\"block\":%u,\"frames\":%llu,\"allFinite\":%s,\"maxBlockDifference\":%.9g,\"mallocCallsDuringRender\":%llu,\"mallocLoggerAvailable\":%s,\"meanMS\":%.9g,\"worstMS\":%.9g}\n",rate,block,(unsigned long long)total,finite?"true":"false",difference,(unsigned long long)allocationCalls,slot?"true":"false",sum/count*1000,worst*1000);fflush(stdout);
 // Jump reset must reproduce a fresh stream, including pending work/OLA/filter state.
 trackedThread.store(reinterpret_cast<uintptr_t>(pthread_self()),std::memory_order_relaxed);core->reset();trackedThread.store(0,std::memory_order_relaxed);float resetDifference=0;for(uint64_t start=0;start<total;start+=block){const uint32_t n=uint32_t(std::min<uint64_t>(block,total-start));for(uint32_t i=0;i<n;++i){left[i]=sample(start+i,0);right[i]=sample(start+i,1);}core->process(in,out,2,n);for(uint32_t i=0;i<n;++i)if(!std::isfinite(out0[i]))pass=false;else resetDifference=std::max(resetDifference,std::abs(out0[i]-result[start+i]));}
 pass&=resetDifference==0;printf("{\"rate\":%.0f,\"block\":%u,\"maxResetDifference\":%.9g}\n",rate,block,resetDifference);
 }
}
if(slot)*slot=saved;return pass?0:2;}

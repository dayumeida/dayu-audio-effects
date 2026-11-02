#include "../大鱼音频效果器Extension/DSP/RealtimeLevelerCore.hpp"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <new>
#include <vector>
static std::atomic<size_t> allocations{0};
void* operator new(size_t n) { allocations.fetch_add(1); if(auto p=std::malloc(n?n:1))return p;throw std::bad_alloc(); }
void operator delete(void* p) noexcept {std::free(p);}
void* operator new[](size_t n) {return ::operator new(n);}
void operator delete[](void* p) noexcept {::operator delete(p);}
static void require(bool condition,const char* text) {if(!condition){std::cerr<<text<<"\n";std::exit(1);}}
using Audio = std::array<std::vector<float>,2>;
static Audio signal(double rate, double seconds) {
    Audio x;for(auto& c:x)c.resize(size_t(rate*seconds));
    for(size_t i=0;i<x[0].size();++i){
        const double t=i/rate;const double a=t<3?.02:t<5?.5:t<7?0:.07;
        x[0][i]=float(a*(.7*std::sin(t*2345)+.3*std::sin(t*985)));
        x[1][i]=x[0][i]*.5f;
    }return x;
}
static Audio render(dayu::RealtimeLevelerCore& core,Audio& input,bool irregular,size_t* during=nullptr){
    Audio output;for(auto& c:output)c.resize(input[0].size());
    const size_t before=allocations.load();
    for(size_t i=0;i<input[0].size();){
        auto n=std::min(input[0].size()-i, irregular?size_t(1+(i*131+17)%777):size_t(1024));
        float* in[]={input[0].data()+i,input[1].data()+i};
        float* out[]={output[0].data()+i,output[1].data()+i};
        core.process(in,out,2,uint32_t(n));i+=n;
    }
    if(during)*during=allocations.load()-before;return output;
}
int main(){
    float maxDifference=0;size_t processAllocations=0;
    for(double rate:{8000.,44100.,48000.,96000.}){
        auto input=signal(rate,18);dayu::RealtimeLevelerCore a,b;a.prepare(rate);b.prepare(rate);
        size_t count=0;auto x=render(a,input,false,&count);processAllocations+=count;
        auto y=render(b,input,true,&count);processAllocations+=count;
        for(size_t i=0;i<x[0].size();++i){
            for(int c=0;c<2;++c){require(std::isfinite(x[c][i]),"nonfinite output");require(std::abs(x[c][i])<=1.000001f,"sample ceiling exceeded");maxDifference=std::max(maxDifference,std::abs(x[c][i]-y[c][i]));}
            require(std::abs(x[1][i]-.5f*x[0][i])<1e-6f,"stereo image changed");
        }
        require(maxDifference==0,"host block size changed audio");
        a.setParameter(1,0);a.reset();x=render(a,input,true,&count);processAllocations+=count;
        const auto delay=a.latencyFrames();
        for(size_t i=0;i<x[0].size();++i) require(x[0][i]==(i<delay?0:input[0][i-delay]),"strength zero is not delayed dry");
        a.setParameter(1,80);a.setBypass(true);a.reset();x=render(a,input,false);
        for(size_t i=0;i<x[0].size();++i) require(x[0][i]==(i<delay?0:input[0][i-delay]),"bypass latency mismatch");
        a.setBypass(false);a.reset();Audio silence;for(auto& c:silence)c.assign(size_t(rate*9),0);
        x=render(a,silence,true);for(auto v:x[0])require(v==0,"reset leaked old audio");
    }
    require(processAllocations==0,"render allocated C++ heap memory");
    dayu::RealtimeLevelerCore core;core.prepare(48000);
    core.setParameter(0,std::numeric_limits<float>::quiet_NaN());require(core.parameter(0)==-3,"NaN parameter not contained");
    core.rampParameter(1,0,101);float inData[256]{},outData[256]{};float*in[]={inData,inData};float*out[]={outData,outData};
    core.process(in,out,1,100);require(core.parameter(1)>0,"parameter ramp ended early");core.process(in,out,1,1);require(core.parameter(1)==0,"parameter ramp did not end");
    core.reset();inData[0]=std::numeric_limits<float>::infinity();inData[1]=std::numeric_limits<float>::quiet_NaN();core.process(in,out,1,256);
    for(float v:outData)require(std::isfinite(v),"malformed host samples escaped");
    std::cout<<"{\"passed\":true,\"rates\":[8000,44100,48000,96000],\"partitionMaxError\":"<<maxDifference<<",\"stereoRatio\":true,\"bypassDelay\":true,\"strengthZeroDry\":true,\"resetSilence\":true,\"parameterRamp\":true,\"processingCppAllocations\":"<<processAllocations<<"}\n";
}

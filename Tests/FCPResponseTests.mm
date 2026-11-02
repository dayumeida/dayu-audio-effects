#include "../大鱼音频效果器Extension/Common/DSP/_______ExtensionAUProcessHelper.hpp"
#include <cstdio>
#include <cstdlib>
#include <cmath>
static void check(bool ok,const char* reason){if(!ok){std::fprintf(stderr,"%s\n",reason);std::exit(1);}}
struct Buffers{UInt32 n;AudioBuffer b[2];};
int main(){
    auto ref=AUProcessHelper::create();auto fast=AUProcessHelper::createLowLatency();
    check(std::abs(ref->latencySeconds()-7.552)<1e-9,"reference latency before allocate");
    check(std::abs(fast->latencySeconds()-.005)<1e-9,"fast latency before allocate");
    check(std::abs(fast->latencySecondsForRate(44100)-221./44100)<1e-9,"44.1k latency rounding");
    check(ref->allocate(48000,2,1024)&&fast->allocate(48000,2,1024),"prepare failed");
    AURenderPullInputBlock pull=^AUAudioUnitStatus(AudioUnitRenderActionFlags*,const AudioTimeStamp* time,AUAudioFrameCount n,NSInteger,AudioBufferList* list){
        for(UInt32 c=0;c<2;++c)for(UInt32 i=0;i<n;++i)
            static_cast<float*>(list->mBuffers[c].mData)[i]=.1f*std::sin(float((time->mSampleTime+i)*.03))*(c?.5f:1.f);
        return noErr;
    };
    auto render=fast->internalRenderBlock();auto reference=ref->internalRenderBlock();
    int goodProbes=0;
    for(int probe=0;probe<20;++probe){
        bool wet=false;AudioTimeStamp t{};t.mFlags=kAudioTimeStampSampleTimeValid;
        for(int block=0;block<4;++block){
            t.mSampleTime=probe*100000+block*1024;
            Buffers out{2,{{1,0,nullptr},{1,0,nullptr}}};AudioUnitRenderActionFlags flags=0;
            check(render(&flags,&t,1024,0,reinterpret_cast<AudioBufferList*>(&out),nullptr,pull)==noErr,"fast render");
            for(int i=0;i<1024;++i)wet|=std::abs(static_cast<float*>(out.b[0].mData)[i])>1e-6f;
            Buffers old{2,{{1,0,nullptr},{1,0,nullptr}}};
            check(reference(&flags,&t,1024,0,reinterpret_cast<AudioBufferList*>(&old),nullptr,pull)==noErr,"reference render");
        }
        check(wet,"random-seek waveform probe stayed blank");
        check(fast->warmupRemainingSeconds()==0,"fast warmup");
        check(ref->warmupRemainingSeconds()>7,"reference should retain old latency");
        check(ref->getWaveformPoint(0,255)>0,"input preview should not await reference output");
        ++goodProbes;
    }
    AUProcessHelper::destroy(fast);AUProcessHelper::destroy(ref);
    std::printf("{\"passed\":true,\"fastLatency48kSeconds\":0.005,\"referenceLatency48kSeconds\":7.552,\"randomSeekProbesWithAudio\":%d,\"referenceLiveInputPreview\":true,\"latencyKnownBeforeAllocation\":true}\n",goodProbes);
}

#include "../大鱼音频效果器Extension/Common/DSP/_______ExtensionAUProcessHelper.hpp"
#include <cstdio>
#include <cstdlib>
#include <vector>
static void check(bool ok,const char* reason){if(!ok){std::fprintf(stderr,"%s\n",reason);std::exit(1);}}
struct Buffers {UInt32 n;AudioBuffer buffers[2];};
int main(){
    auto helper=AUProcessHelper::create();check(helper->allocate(48000,2,1024),"allocation failed");
    helper->setParameter(1,0); // delayed dry permits an exact routing check.
    auto render=helper->internalRenderBlock();
    __block uint64_t position=0;
    AURenderPullInputBlock pull=^AUAudioUnitStatus(AudioUnitRenderActionFlags*,const AudioTimeStamp*,AUAudioFrameCount n,NSInteger,AudioBufferList* data){
        for(UInt32 c=0;c<data->mNumberBuffers;++c)for(UInt32 i=0;i<n;++i)
            static_cast<float*>(data->mBuffers[c].mData)[i]=float(((position+i)%97)*.001)*(c? .5f:1.f);
        position+=n;return noErr;
    };
    AudioTimeStamp time{};time.mFlags=kAudioTimeStampSampleTimeValid;
    Buffers b{2,{{1,0,nullptr},{1,0,nullptr}}};
    AudioUnitRenderActionFlags flags=0;
    uint32_t first=UINT32_MAX;
    for(uint32_t start=0;start<400000;start+=64){
        time.mSampleTime=start;b.buffers[0].mData=b.buffers[1].mData=nullptr;
        AURenderEvent future{};future.head.eventType=AURenderEventParameter;
        future.parameter.parameterAddress=1;future.parameter.value=0;
        future.parameter.eventSampleTime=start+10000; // must not underflow segment length.
        check(render(&flags,&time,64,0,reinterpret_cast<AudioBufferList*>(&b),&future,pull)==noErr,"render failed");
        check(b.buffers[0].mData&&b.buffers[1].mData,"null output was not supplied");
        for(uint32_t i=0;i<64;++i){
            const auto absolute=start+i;const auto delay=uint32_t(helper->latencySeconds()*48000+.5);
            const float expected=absolute<delay?0:float(((absolute-delay)%97)*.001);
            const float got=static_cast<float*>(b.buffers[0].mData)[i];
            check(got==expected,"pull/delay/event routing mismatch");
            if(got!=0&&first==UINT32_MAX)first=absolute;
        }
    }
    check(first==362497,"first audible sample not exact");
    check(render(&flags,&time,1025,0,reinterpret_cast<AudioBufferList*>(&b),nullptr,pull)==kAudioUnitErr_TooManyFramesToProcess,"oversized block accepted");
    check(render(&flags,&time,64,1,reinterpret_cast<AudioBufferList*>(&b),nullptr,pull)==kAudioUnitErr_InvalidElement,"invalid bus accepted");
    check(render(&flags,&time,64,0,reinterpret_cast<AudioBufferList*>(&b),nullptr,nil)==kAudioUnitErr_NoConnection,"missing input accepted");
    // A seek must flush all old delayed audio.
    time.mSampleTime=900000;position=0;b.buffers[0].mData=b.buffers[1].mData=nullptr;
    check(render(&flags,&time,64,0,reinterpret_cast<AudioBufferList*>(&b),nullptr,pull)==noErr,"seek failed");
    for(uint32_t i=0;i<64;++i)check(static_cast<float*>(b.buffers[0].mData)[i]==0,"seek leaked buffered audio");
    AUProcessHelper::destroy(helper);
    std::puts("{\"passed\":true,\"pullInput\":true,\"nullOutputBuffers\":true,\"futureEventClamp\":true,\"seekReset\":true,\"invalidBusAndBlock\":true,\"firstNonzeroFrame\":362497}");
}

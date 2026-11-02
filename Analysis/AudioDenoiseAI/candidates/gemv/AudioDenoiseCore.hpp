#pragma once
#include "DenoiseInference.hpp"
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>
#include <memory>
#include "CDSPResampler.h"
// Working model port. See report.md for resampling and host-wrapper differences.
// No files, allocation, locks, waits, or threads in reset/process/parameter methods.
namespace dayu {
class AudioDenoiseCore {
public:
 // Actual audio controls only. Vendor Profile is preset data, Analyzing is status.
 // 0 Strength, 1 OutputGain, 2 Low, 3 Mid, 4 High, 5 Active.
 static constexpr uint32_t parameterCount=8;
 inline static constexpr std::array<float,8>defaults={0,1,80,0,100,100,100,0};
 inline static constexpr std::array<float,8>minima={0,0,0,-24,0,0,0,0};
 inline static constexpr std::array<float,8>maxima={1,1,100,24,100,100,100,100};
 static float sanitize(uint32_t id,float v)noexcept{return id<8?(std::isfinite(v)?std::clamp(v,minima[id],maxima[id]):defaults[id]):0;}
 // MUST be called on control thread before allocate/render. Failure must fail AU allocation.
 bool loadModel(const char*path){ready_=net_.prepare(path);return ready_;}
 bool modelReady()const noexcept{return ready_;}
 static uint32_t latencyFramesForRate(double rate)noexcept{return uint32_t(std::ceil(rate*.64))+2;}
 void prepare(double rate){
  rate_=std::isfinite(rate)&&rate>=8000&&rate<=384000?rate:48000;
  delay_=latencyFramesForRate(rate_);drySize_=delay_+1;
  for(auto&b:dry_)b.assign(drySize_,0);
  windowFrames_=int(std::floor(rate_*16384./32000.));crop_=int(std::floor(rate_*4128./32000.));hop_=windowFrames_-2*crop_-128;
  sourceSize_=size_t(std::ceil(rate_*2))+16;sourceMono_.assign(sourceSize_,0);wetHost_.assign(sourceSize_,0);
  hostInput_.assign(std::max(64000,windowFrames_*2),0);resampleInput_.assign(std::max(64000,windowFrames_*2),0);resampled_.assign(std::max(16384,windowFrames_),0);
  down_=std::make_unique<r8b::CDSPResampler>(rate_,32000.,windowFrames_*2,2.,206.91,r8b::fprLinearPhase);
  up_=std::make_unique<r8b::CDSPResampler>(32000.,rate_,64000,2.,206.91,r8b::fprLinearPhase);
  // Warm up resamplers and their FFT paths outside rendering.
  resample(*down_,hostInput_.data(),windowFrames_,modelInput_.data(),16384,windowFrames_*2);
  resample(*up_,hostInput_.data(),16384,resampled_.data(),windowFrames_,64000);
  jobCost_=dayu_denoise::Inference::totalCost()+double((windowFrames_+255)/256*2+(16384+255)/256*3+64)*256000.;
  lowCross_.prepare(64000,500);highCross_.prepare(64000,4000);lowAllpass_.prepareAllpass(64000,4000);
  reset();
 }
 void reset()noexcept{
  std::fill(sourceMono_.begin(),sourceMono_.end(),0);std::fill(wetHost_.begin(),wetHost_.end(),0);for(auto&b:dry_)std::fill(b.begin(),b.end(),0);
  net_.reset();stage_=Stage::idle;cursor_=produced_=0;lowCross_.reset();highCross_.reset();lowAllpass_.reset();
  hostFrame_=0;windowStart_=-crop_;jobStart_=0;credit_=0;
  previous_={};dryWrite_=0;validWetThrough_=-1;wavePosition_=meterFrames_=0;
  meterInput_=meterOutput_=0;inputPeak_=outputPeak_=0;meters_={-120,-120,0,0};
  for(auto&b:wave_)b.fill(0);bypassMix_=bypass_?1.f:0.f;mask_=0;
 }
 void setParameter(uint32_t id,float v)noexcept{if(id<8&&id!=0&&id!=7){values_[id]=sanitize(id,v);mask_&=~(1u<<id);}}
 void rampParameter(uint32_t id,float v,uint32_t n)noexcept{if(id>=8||id==0||id==7)return;if(!n){setParameter(id,v);return;}v=sanitize(id,v);ramps_[id]={v,(v-values_[id])/n,n};mask_|=1u<<id;}
 float parameter(uint32_t id)const noexcept{return id<8?values_[id]:0;}
 void setBypass(bool b)noexcept{bypass_=b;}
 uint32_t latencyFrames()const noexcept{return delay_;}
 double latencySeconds()const noexcept{return double(delay_)/rate_;}
 float meter(uint32_t id)const noexcept{return id<4?meters_[id]:0;}
 float waveform(uint32_t s,uint32_t i)const noexcept{return s<2&&i<256?wave_[s][(wavePosition_+i)%256]:0;}
 void process(float*const*input,float*const*output,uint32_t channels,uint32_t frames)noexcept{
  if(channels<1||channels>2||!drySize_)return;
  for(uint32_t i=0;i<frames;++i){
   advanceRamps();std::array<float,2>in{};float ip=0;
   for(uint32_t c=0;c<channels;++c){const float x=input[c][i];in[c]=std::isfinite(x)?std::clamp(x,-16.f,16.f):0.f;ip=std::max(ip,std::abs(in[c]));dry_[c][dryWrite_]=in[c];}
   if(channels==1)in[1]=in[0];
   sourceMono_[hostIndex(hostFrame_)]=channels==1?in[0]:(in[0]+in[1])*.5f;
   if(ready_&&stage_==Stage::idle&&hostFrame_+1>=windowStart_+windowFrames_){
    jobStart_=windowStart_;windowStart_+=hop_;cursor_=produced_=0;credit_=0;stage_=Stage::gather;
   }
   if(stage_!=Stage::idle){
    credit_+=jobCost_/(rate_*.225);
    while(stage_!=Stage::idle&&credit_>=nextCost()){credit_-=nextCost();jobStep();}
   }
   const uint32_t read=(dryWrite_+1)%drySize_;
   const int64_t sourceFrame=hostFrame_-delay_;float clean=sourceFrame>=0&&sourceFrame<=validWetThrough_?wetHost_[hostIndex(sourceFrame)]:0;
   const float strength=values_[2]*.01f;const float gain=std::pow(10.f,values_[3]*.05f);
   const float target=(bypass_||values_[1]<.5f||!ready_)?1.f:0.f;
   bypassMix_+=std::clamp(target-bypassMix_,-float(1./(rate_*.005)),float(1./(rate_*.005)));
   float op=0;
   for(uint32_t c=0;c<channels;++c){const float dry=dry_[c][read];const float wet=(dry*(1-strength)+clean*strength)*gain;float y=wet+(dry-wet)*bypassMix_;if(!std::isfinite(y))y=0;output[c][i]=y;op=std::max(op,std::abs(y));}
   meterInput_+=double(ip)*ip;meterOutput_+=double(op)*op;inputPeak_=std::max(inputPeak_,ip);outputPeak_=std::max(outputPeak_,op);
   if(++meterFrames_>=uint32_t(std::max(1.,rate_*.01))){meters_[0]=db(std::sqrt(meterInput_/meterFrames_));meters_[1]=db(std::sqrt(meterOutput_/meterFrames_));meters_[2]=meters_[0]-meters_[1];meters_[3]=stage_!=Stage::idle?1:0;
    wave_[0][wavePosition_]=std::min(1.f,inputPeak_);wave_[1][wavePosition_]=std::min(1.f,outputPeak_);wavePosition_=(wavePosition_+1)%256;meterFrames_=0;meterInput_=meterOutput_=0;inputPeak_=outputPeak_=0;}
   dryWrite_=read;++hostFrame_;
  }
 }
private:
 struct Biquad{
  double a1=0,a2=0,b0=1,b1=0,b2=0,z1=0,z2=0,denormal=1.e-8;
  void prepare(double rate,double f,bool high){const double w=2*3.14159265358979323846*f/rate,c=std::cos(w),a=std::sin(w)*.7071067811865475244,n=1/(1+a);a1=-2*c*n;a2=(1-a)*n;b0=(high?(1+c):(1-c))*.5*n;b1=(high?-(1+c):(1-c))*n;b2=b0;reset();}
  void prepareAllpass(double rate,double f){const double w=2*3.14159265358979323846*f/rate,c=std::cos(w),a=std::sin(w),n=1/(1+a);a1=-2*c*n;a2=(1-a)*n;b0=a2;b1=a1;b2=1;reset();}
  void reset()noexcept{z1=z2=0;denormal=1.e-8;}
  float process(float x)noexcept{double w=std::fma(z2,a2,denormal);w=std::fma(z1,a1,w);w=double(x)-w;double y=z2*b2;y=std::fma(z1,b1,y);y=std::fma(w,b0,y);z2=z1;z1=w;denormal=-denormal;return float(y);}
 };
 struct LR{
  Biquad l1,l2,h1,h2;
  void prepare(double rate,double f){l1.prepare(rate,f,false);l2.prepare(rate,f,false);h1.prepare(rate,f,true);h2.prepare(rate,f,true);}
  void reset()noexcept{l1.reset();l2.reset();h1.reset();h2.reset();}
  std::array<float,2>process(float x)noexcept{return {l2.process(l1.process(x)),h2.process(h1.process(x))};}
 };
 static size_t index(int64_t n)noexcept{return size_t(n)&65535;}
 static float db(double x)noexcept{return float(20*std::log10(std::max(x,1.e-6)));}
 size_t hostIndex(int64_t n)const noexcept{return size_t(n%int64_t(sourceSize_)+int64_t(sourceSize_))%sourceSize_;}
 void resample(r8b::CDSPResampler&converter,const double*input,int inputFrames,float*output,int outputFrames,int maxInput)noexcept{
  converter.clear();int produced=0;bool first=true;
  while(produced<outputFrames){const int n=first?inputFrames:maxInput;
   if(first)std::copy(input,input+n,resampleInput_.begin());else std::fill(resampleInput_.begin(),resampleInput_.begin()+n,0.);
   double*out=nullptr;const int count=converter.process(resampleInput_.data(),n,out);const int copy=std::min(count,outputFrames-produced);
   for(int j=0;j<copy;++j)output[produced+j]=float(out[j]);produced+=copy;first=false;
  }
  converter.clear();
 }
 enum class Stage {idle,gather,down,network,residual,up,publish};
 double nextCost()const noexcept{return stage_==Stage::network?net_.nextStepCost():256000.;}
 void jobStep()noexcept{
  if(stage_==Stage::gather){
   const int end=std::min(windowFrames_,cursor_+256);for(int j=cursor_;j<end;++j){const int64_t p=jobStart_+j;hostInput_[j]=p<0?0:sourceMono_[hostIndex(p)];}cursor_=end;
   if(cursor_==windowFrames_){cursor_=produced_=0;down_->clear();stage_=Stage::down;}return;
  }
  if(stage_==Stage::down||stage_==Stage::up){
   const bool down=stage_==Stage::down;const int inputFrames=down?windowFrames_:16384,outputFrames=down?16384:windowFrames_;
   const int n=cursor_<inputFrames?std::min(256,inputFrames-cursor_):256;
   for(int j=0;j<n;++j)resampleInput_[j]=cursor_<inputFrames?hostInput_[cursor_+j]:0.;
   double*out=nullptr;const int count=(down?down_.get():up_.get())->process(resampleInput_.data(),n,out);const int copy=std::min(count,outputFrames-produced_);
   float*dest=down?modelInput_.data():resampled_.data();for(int j=0;j<copy;++j)dest[produced_+j]=float(out[j]);produced_+=copy;cursor_+=n;
   if(produced_==outputFrames){(down?down_.get():up_.get())->clear();cursor_=produced_=0;if(down){net_.begin(modelInput_.data());stage_=Stage::network;}else stage_=Stage::publish;}return;
  }
  if(stage_==Stage::network){if(net_.step()){cursor_=0;stage_=Stage::residual;}return;}
  if(stage_==Stage::residual){
   const float*clean=net_.output();const bool split=values_[4]<100||values_[5]<100||values_[6]<100;const int end=std::min(16384,cursor_+256);
   for(int j=cursor_;j<end;++j){float y=clean[j];if(split){auto lohi=lowCross_.process(modelInput_[j]-y);auto midhi=highCross_.process(lohi[1]);const float low=lowAllpass_.process(lohi[0]);y+=low*(1-values_[4]*.01f)+midhi[0]*(1-values_[5]*.01f)+midhi[1]*(1-values_[6]*.01f);}hostInput_[j]=y;}cursor_=end;
   if(cursor_==16384){cursor_=produced_=0;up_->clear();stage_=Stage::up;}return;
  }
  if(stage_==Stage::publish){
   const int end=std::min(windowFrames_-crop_,crop_+cursor_+256);
   for(int j=crop_+cursor_;j<end;++j){const int k=j-crop_;const int64_t p=jobStart_+j;float&dest=wetHost_[hostIndex(p)];const float y=resampled_[j];if(k<128&&p<=validWetThrough_)dest=dest*(1-k/128.f)+y*(k/128.f);else dest=y;}
   cursor_=end-crop_;if(end==windowFrames_-crop_){validWetThrough_=jobStart_+end-1;stage_=Stage::idle;}return;
  }
 }
 struct Ramp{float target=0,step=0;uint32_t frames=0;};
 void advanceRamps()noexcept{for(uint32_t id=0;id<8;++id)if(mask_&(1u<<id)){auto&r=ramps_[id];values_[id]+=r.step;if(!--r.frames){values_[id]=r.target;mask_&=~(1u<<id);}}}
 dayu_denoise::Inference net_;bool ready_=false,bypass_=false;float bypassMix_=0;
 std::array<float,8>values_=defaults;std::array<Ramp,8>ramps_{};uint32_t mask_=0;
 std::vector<float>sourceMono_,wetHost_,resampled_;std::vector<double>hostInput_,resampleInput_;size_t sourceSize_=0;int windowFrames_=0,crop_=0,hop_=0;std::unique_ptr<r8b::CDSPResampler>down_,up_;std::array<float,16384>modelInput_{};
 std::array<std::vector<float>,2>dry_;std::array<float,2>previous_{};uint32_t delay_=0,drySize_=0,dryWrite_=0;
 int64_t hostFrame_=0,windowStart_=0,jobStart_=0,validWetThrough_=-1;double rate_=48000,credit_=0,jobCost_=1;Stage stage_=Stage::idle;int cursor_=0,produced_=0;
 LR lowCross_,highCross_;Biquad lowAllpass_;
 std::array<float,4>meters_={-120,-120,0,0};std::array<std::array<float,256>,2>wave_{};uint32_t wavePosition_=0,meterFrames_=0;double meterInput_=0,meterOutput_=0;float inputPeak_=0,outputPeak_=0;
};
}

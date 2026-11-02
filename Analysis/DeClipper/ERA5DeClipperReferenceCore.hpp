#pragma once
// Full streaming wrapper draft. The target maths are independently reconstructed
// from the installed ERA5 5.4.00 arm64; see evidence/comparisons in this directory.
// Do not register until whole-AU output checks (including both Processing Types) pass.
#include "RecoveredDetector.hpp"
#include "RecoveredSegments.hpp"
#include "RecoveredLimiter.hpp"
#include "Repair/RecoveredRepairLoop.hpp"
#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>
namespace dayu {
class ERA5DeClipperReferenceCore {
 using Region=recovered::RepairLoop::Region;
public:
 static constexpr uint32_t parameterCount=5;
 inline static constexpr std::array<float,5>defaults={0,1,0,0,1},minima={0,0,0,-30,0},maxima={1,1,1,5,1};
 static float sanitize(uint32_t id,float v)noexcept{return id<parameterCount?(std::isfinite(v)?std::clamp(v,minima[id],maxima[id]):defaults[id]):0.f;}
 static bool supportsRate(double rate)noexcept{return std::isfinite(rate)&&rate>=16000&&rate<=384000;}
 static uint32_t analysisFramesForRate(double rate)noexcept{return uint32_t(std::lround(((700./44100.+700./44100.)+3000./44100.+400./44100.)*rate));}
 static uint32_t latencyFramesForRate(double rate)noexcept{return analysisFramesForRate(rate)+uint32_t(std::lround(rate*.003));}
 void prepare(double rate){
  rate_=supportsRate(rate)?rate:48000.;n_=int(analysisFramesForRate(rate_));
  context_=int(std::lround((700./44100.)*rate_));limit_=int(std::lround((3000./44100.)*rate_));
  hop_=limit_-context_;spline_=int(std::lround((20./44100.)*rate_));maximumRegion_=int((400./44100.)*rate_);
  latency_=latencyFramesForRate(rate_);bypassStep_=float(1./(rate_*.005));meterHop_=std::max(1u,uint32_t(rate_*.01));
  detector_.prepare(rate_);segments_.prepare(n_,hop_,maximumRegion_);repair_.prepare(n_,150);limiter_.prepare(rate_);
  for(unsigned c=0;c<2;++c){analysis_[c].resize(n_);audio_[c].resize(n_);original_[c].resize(n_);input_[c].resize(hop_);output_[c].resize(hop_);dry_[c].resize(latency_+1);regions_[c].resize(size_t(n_)*2+8);}
  reset();
 }
 void reset()noexcept{
  for(unsigned c=0;c<2;++c){for(auto*b:{&analysis_[c],&audio_[c],&original_[c]})std::fill(b->begin(),b->end(),0.);for(auto*b:{&input_[c],&output_[c],&dry_[c]})std::fill(b->begin(),b->end(),0.f);counts_[c]=0;}
  detector_.reset();segments_.reset();repair_.reset();limiter_.reset();fill_=read_=available_=dryPosition_=0;channels_=0;meterTicks_=wavePosition_=0;inputEnergy_=outputEnergy_=0.;waveIn_=waveOut_=0.;
  for(auto&v:waves_)v.fill(0);meters_={-120,-120,0,0};bypassMix_=(bypass_||values_[1]<.5f)?1.f:0.f;rampMask_=0;
 }
 void setParameter(uint32_t id,float v)noexcept{if(id>=5)return;values_[id]=sanitize(id,v);rampMask_&=~(1u<<id);}
 void rampParameter(uint32_t id,float v,uint32_t frames)noexcept{if(id>=5)return;v=sanitize(id,v);if(!frames){setParameter(id,v);return;}ramps_[id]={v,(v-values_[id])/frames,frames};rampMask_|=1u<<id;}
 float parameter(uint32_t id)const noexcept{return id<5?values_[id]:0.f;}
 void setBypass(bool b)noexcept{bypass_=b;}
 uint32_t latencyFrames()const noexcept{return latency_;}
 double latencySeconds()const noexcept{return latency_/rate_;}
 float meter(uint32_t id)const noexcept{return id<4?meters_[id]:0.f;}
 float waveform(uint32_t stream,uint32_t index)const noexcept{return stream<2&&index<256?waves_[stream][(wavePosition_+index)%256]:0.f;}
 void process(float*const* inputs,float*const* outputs,uint32_t channels,uint32_t frames)noexcept{
  if(!inputs||!outputs||channels<1||channels>2||hop_<1)return;
  if(channels_==0)channels_=channels;
  for(uint32_t i=0;i<frames;++i){
   advance();float inputPeak=0.f,outputPeak=0.f,delayedPeak=0.f;std::array<float,2>raw{},dry{};
   const auto dryRead=(dryPosition_+1)%dry_[0].size();
   for(unsigned c=0;c<channels;++c){float x=inputs[c][i];if(!std::isfinite(x))x=0.f;raw[c]=std::clamp(x,-64.f,64.f);input_[c][fill_]=raw[c];inputPeak=std::max(inputPeak,std::abs(raw[c]));dry_[c][dryPosition_]=raw[c];dry[c]=dry_[c][dryRead];delayedPeak=std::max(delayedPeak,std::abs(dry[c]));}
   const float target=(bypass_||values_[1]<.5f)?1.f:0.f;bypassMix_+=std::clamp(target-bypassMix_,-bypassStep_,bypassStep_);
   for(unsigned c=0;c<channels;++c){const float wet=available_?output_[c][read_]:0.f;const float y=wet+bypassMix_*(dry[c]-wet);outputs[c][i]=std::isfinite(y)?y:0.f;outputPeak=std::max(outputPeak,std::abs(outputs[c][i]));}
   dryPosition_=dryRead;if(available_){++read_;--available_;}
   inputEnergy_+=double(inputPeak)*inputPeak;outputEnergy_+=double(outputPeak)*outputPeak;waveIn_=std::max(waveIn_,delayedPeak);waveOut_=std::max(waveOut_,outputPeak);
   if(++meterTicks_==meterHop_){meters_[0]=float(10.*std::log10(std::max(inputEnergy_/meterTicks_,1e-12)));meters_[1]=float(10.*std::log10(std::max(outputEnergy_/meterTicks_,1e-12)));meters_[2]=std::max(0.f,meters_[0]-meters_[1]);waves_[0][wavePosition_]=std::min(1.f,waveIn_);waves_[1][wavePosition_]=std::min(1.f,waveOut_);wavePosition_=(wavePosition_+1)%256;inputEnergy_=outputEnergy_=0.;waveIn_=waveOut_=0.f;meterTicks_=0;}
   if(++fill_==unsigned(hop_)){processHop(channels);fill_=read_=0;available_=hop_;}
  }
 }
private:
 void updateRegions(unsigned ch,const declip::Region*incoming,int incomingCount)noexcept{
  auto& list=regions_[ch];int count=counts_[ch],expired=-1;
  for(int i=0;i<count;++i)if(list[i].end<hop_)expired=i;
  if(expired>=0){const int retain=count-expired-1;for(int i=0;i<retain;++i)list[i]=list[i+expired+1];count=retain;}
  for(int i=0;i<count;++i){list[i].start-=hop_;list[i].end-=hop_;if(list[i].start<0&&list[i].end>-1)list[i].start=0;}
  int begin=0;
  if(incomingCount>0&&count>0&&list[count-1].end+1==incoming[0].start&&incoming[0].end-list[count-1].start<maximumRegion_){list[count-1].end=incoming[0].end;begin=1;}
  for(int i=begin;i<incomingCount&&count<int(list.size());++i)list[count++]={incoming[i].status,incoming[i].start,incoming[i].end};counts_[ch]=count;
 }
 void processHop(unsigned channels)noexcept{
  const bool type2=values_[2]>=.5f;const int quality=values_[0]>=.5f?1:0;
  const double gain=double(::__exp10f(values_[3]*.05f));double activity=0.;
  for(unsigned c=0;c<channels;++c){
   for(auto*b:{&analysis_[c],&audio_[c],&original_[c]})std::memmove(b->data(),b->data()+hop_,size_t(n_-hop_)*8);
   for(int i=0;i<hop_;++i){const double v=double(input_[c][i]);analysis_[c][n_-hop_+i]=v;audio_[c][n_-hop_+i]=v;original_[c][n_-hop_+i]=v;}
   const auto& d=detector_.process(analysis_[c].data(),n_,c,type2);segments_.process(analysis_[c].data(),d,type2);activity=std::max(activity,segments_.repairedFraction());updateRegions(c,segments_.data(),segments_.count());
   repair_.process(audio_[c].data(),n_,regions_[c].data(),counts_[c],c,context_,spline_,limit_,quality?150:100,quality);
   for(int i=0;i<hop_;++i)output_[c][i]=float((values_[4]>=.5f?audio_[c][i]:original_[c][i])*gain);
  }
  std::array<float*,2>p={output_[0].data(),output_[1].data()};limiter_.process(p.data(),channels,hop_);meters_[3]=float(std::clamp(activity,0.,1.));
 }
 struct Ramp{float target=0,step=0;uint32_t remaining=0;};
 void advance()noexcept{for(unsigned id=0;id<5;++id)if(rampMask_&(1u<<id)){auto&r=ramps_[id];values_[id]+=r.step;if(--r.remaining==0){values_[id]=r.target;rampMask_&=~(1u<<id);}}}
 double rate_=48000;int n_=0,hop_=0,context_=0,spline_=0,limit_=0,maximumRegion_=0;uint32_t latency_=0,fill_=0,read_=0,available_=0,channels_=0;size_t dryPosition_=0;
 declip::RecoveredDetector detector_;declip::RecoveredSegments segments_;recovered::RepairLoop repair_;declip::RecoveredLimiter limiter_;
 std::array<std::vector<double>,2>analysis_,audio_,original_;std::array<std::vector<float>,2>input_,output_,dry_;std::array<std::vector<Region>,2>regions_;std::array<int,2>counts_{};
 std::array<float,5>values_=defaults;std::array<Ramp,5>ramps_{};uint32_t rampMask_=0;bool bypass_=false;float bypassMix_=0,bypassStep_=0;
 std::array<float,4>meters_{};std::array<std::array<float,256>,2>waves_{};uint32_t meterTicks_=0,meterHop_=480,wavePosition_=0;double inputEnergy_=0,outputEnergy_=0;float waveIn_=0,waveOut_=0;
};
}

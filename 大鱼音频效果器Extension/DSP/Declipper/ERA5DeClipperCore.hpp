#pragma once
// ERA5 5.4.00 arm64 reconstruction. Work is distributed over a fixed extra hop.
// All buffers are allocated in prepare; process never allocates, locks or waits.
// The source's residual-buffer overread is deliberately repaired with zero input
// after the valid LPC convolution terms. See RECONSTRUCTION.md.
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
class ERA5DeClipperCore {
 using Region=recovered::RepairLoop::Region;
public:
 static constexpr uint32_t parameterCount=5;
 inline static constexpr std::array<float,5>defaults={0,1,0,0,1},minima={0,0,0,-30,0},maxima={1,1,1,5,1};
 static float sanitize(uint32_t id,float v)noexcept{return id<parameterCount?(std::isfinite(v)?std::clamp(v,minima[id],maxima[id]):defaults[id]):0.f;}
 static bool supportsRate(double rate)noexcept{return std::isfinite(rate)&&rate>=16000&&rate<=384000;}
 static uint32_t analysisFramesForRate(double rate)noexcept{return uint32_t(std::lround(((700./44100.+700./44100.)+3000./44100.+400./44100.)*rate));}
 static uint32_t hopFramesForRate(double rate)noexcept{return uint32_t(std::lround((3000./44100.)*rate)-std::lround((700./44100.)*rate));}
 static uint32_t latencyFramesForRate(double rate)noexcept{return analysisFramesForRate(rate)+hopFramesForRate(rate)+uint32_t(std::round((float(rate)*3.f)*float(.001)));}
 void prepare(double rate){
  rate_=supportsRate(rate)?rate:48000.;n_=int(analysisFramesForRate(rate_));
  context_=int(std::lround((700./44100.)*rate_));limit_=int(std::lround((3000./44100.)*rate_));
  hop_=limit_-context_;spline_=int(std::lround((20./44100.)*rate_));maximumRegion_=int((400./44100.)*rate_);
  latency_=latencyFramesForRate(rate_);bypassStep_=float(1./(rate_*.005));meterHop_=std::max(1u,uint32_t(rate_*.01));
  detector_.prepare(rate_);segments_.prepare(n_,hop_,maximumRegion_);repair_.prepare(n_,150);repair_.setReferenceHeapTail(false);limiter_.prepare(rate_);
  for(unsigned c=0;c<2;++c){analysis_[c].resize(n_);audio_[c].resize(n_);original_[c].resize(n_);input_[c].resize(hop_);output_[c].resize(hop_);pending_[c].resize(hop_);dry_[c].resize(latency_+1);regions_[c].resize(size_t(n_)*2+8);}
  reset();
 }
 void reset()noexcept{
  repair_.reset();detector_.reset();segments_.reset();limiter_.reset();
  for(unsigned c=0;c<2;++c){for(auto*b:{&analysis_[c],&audio_[c],&original_[c]})std::fill(b->begin(),b->end(),0.);for(auto*b:{&input_[c],&output_[c],&pending_[c],&dry_[c]})std::fill(b->begin(),b->end(),0.f);counts_[c]=0;}
  fill_=read_=available_=dryPosition_=0;channels_=0;meterTicks_=wavePosition_=0;inputEnergy_=outputEnergy_=0.;waveIn_=waveOut_=0.;
  for(auto&v:waves_)v.fill(0);meters_={-120,-120,0,0};bypassMix_=(bypass_||values_[1]<.5f)?1.f:0.f;rampMask_=0;
  jobStage_=JobStage::Idle;jobChannel_=jobOffset_=jobAge_=0;costPerFrame_=1.;workCredit_=0.;deadlineMisses_=0;jobUnits_=maximumJobUnits_=0;
 }
 void setParameter(uint32_t id,float v)noexcept{if(id>=5)return;values_[id]=sanitize(id,v);rampMask_&=~(1u<<id);}
 void rampParameter(uint32_t id,float v,uint32_t frames)noexcept{if(id>=5)return;v=sanitize(id,v);if(!frames){setParameter(id,v);return;}ramps_[id]={v,(v-values_[id])/frames,frames};rampMask_|=1u<<id;}
 float parameter(uint32_t id)const noexcept{return id<5?values_[id]:0.f;}
 void setBypass(bool b)noexcept{bypass_=b;}
 uint32_t latencyFrames()const noexcept{return latency_;}
 double latencySeconds()const noexcept{return latency_/rate_;}
 float meter(uint32_t id)const noexcept{return id<4?meters_[id]:0.f;}
 float waveform(uint32_t stream,uint32_t index)const noexcept{return stream<2&&index<256?waves_[stream][(wavePosition_+index)%256]:0.f;}
 uint64_t deadlineMisses()const noexcept{return deadlineMisses_;}
 uint64_t maximumJobUnits()const noexcept{return maximumJobUnits_;}
 void process(float*const* inputs,float*const* outputs,uint32_t channels,uint32_t frames)noexcept{
  if(!inputs||!outputs||channels<1||channels>2||hop_<1)return;
  if(channels_==0)channels_=channels;
  for(uint32_t i=0;i<frames;++i){
   advance();float inputPeak=0.f,outputPeak=0.f,delayedPeak=0.f;std::array<float,2>raw{},dry{};
   const auto dryRead=(dryPosition_+1)%dry_[0].size();
   for(unsigned c=0;c<channels;++c){float x=inputs[c][i];if(!std::isfinite(x))x=0.f;raw[c]=std::clamp(x,-64.f,64.f);input_[c][fill_]=raw[c];inputPeak=std::max(inputPeak,std::abs(raw[c]));dry_[c][dryPosition_]=raw[c];dry[c]=dry_[c][dryRead];delayedPeak=std::max(delayedPeak,std::abs(dry[c]));}
   const float target=(bypass_||values_[1]<.5f)?1.f:0.f;bypassMix_+=std::clamp(target-bypassMix_,-bypassStep_,bypassStep_);
   for(unsigned c=0;c<channels;++c){const float wet=available_?output_[c][read_]:0.f;const float y=bypassMix_<=0.f?wet:(bypassMix_>=1.f?dry[c]:wet+bypassMix_*(dry[c]-wet));outputs[c][i]=std::isfinite(y)?y:0.f;outputPeak=std::max(outputPeak,std::abs(outputs[c][i]));}
   dryPosition_=dryRead;if(available_){++read_;--available_;}
   inputEnergy_+=double(inputPeak)*inputPeak;outputEnergy_+=double(outputPeak)*outputPeak;waveIn_=std::max(waveIn_,delayedPeak);waveOut_=std::max(waveOut_,outputPeak);
   if(++meterTicks_==meterHop_){meters_[0]=float(10.*std::log10(std::max(inputEnergy_/meterTicks_,1e-12)));meters_[1]=float(10.*std::log10(std::max(outputEnergy_/meterTicks_,1e-12)));meters_[2]=std::max(0.f,meters_[0]-meters_[1]);waves_[0][wavePosition_]=std::min(1.f,waveIn_);waves_[1][wavePosition_]=std::min(1.f,waveOut_);wavePosition_=(wavePosition_+1)%256;inputEnergy_=outputEnergy_=0.;waveIn_=waveOut_=0.f;meterTicks_=0;}
   if(jobStage_!=JobStage::Idle&&jobStage_!=JobStage::Done){++jobAge_;pacedWork();}
   if(++fill_==unsigned(hop_)){
    if(jobStage_!=JobStage::Idle){
     if(jobStage_!=JobStage::Done){++deadlineMisses_;while(jobStage_!=JobStage::Done)work(1024);}
     for(unsigned c=0;c<channels;++c)std::copy(pending_[c].begin(),pending_[c].end(),output_[c].begin());
     read_=0;available_=hop_;maximumJobUnits_=std::max(maximumJobUnits_,jobUnits_);
    }
    beginJob(channels);fill_=0;
   }
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
 void beginJob(unsigned channels)noexcept{
  jobChannels_=channels;jobType2_=values_[2]>=.5f;jobQuality_=values_[0]>=.5f?1:0;jobDeclip_=values_[4]>=.5f;jobGain_=double(::__exp10f(values_[3]*.05f));jobActivity_=0.;jobChannel_=jobOffset_=jobAge_=0;jobUnits_=0;costPerFrame_=1.;workCredit_=0.;
  for(unsigned c=0;c<channels;++c){for(auto*b:{&analysis_[c],&audio_[c],&original_[c]})std::memmove(b->data(),b->data()+hop_,size_t(n_-hop_)*8);for(int i=0;i<hop_;++i){const double v=double(input_[c][i]);analysis_[c][n_-hop_+i]=v;audio_[c][n_-hop_+i]=v;original_[c][n_-hop_+i]=v;}}
  jobStage_=JobStage::Detect;
 }
 double nextJobCost()const noexcept{
  switch(jobStage_){case JobStage::Repair:return std::max(.000001,repair_.nextCost());case JobStage::Sanitize:return .25;case JobStage::Convert:return .5;case JobStage::Limit:return 4.;default:return .5;}
 }
 void pacedWork()noexcept{
  if(jobStage_==JobStage::Detect){work(1);return;}
  workCredit_+=costPerFrame_;
  while(jobStage_!=JobStage::Done&&jobStage_!=JobStage::Idle){const double cost=nextJobCost();if(workCredit_<cost)break;workCredit_-=cost;work(1);}
 }
 void work(uint32_t units)noexcept{
  while(units&&jobStage_!=JobStage::Done&&jobStage_!=JobStage::Idle){
   switch(jobStage_){
    case JobStage::Detect:{const unsigned c=jobChannel_;const auto&d=detector_.process(analysis_[c].data(),n_,c,jobType2_);segments_.process(analysis_[c].data(),d,jobType2_);jobActivity_=std::max(jobActivity_,segments_.repairedFraction());updateRegions(c,segments_.data(),segments_.count());
     if(++jobChannel_==jobChannels_){double total=256.;for(unsigned c=0;c<jobChannels_;++c)total+=repair_.estimatedCost(n_,regions_[c].data(),counts_[c],context_,limit_,jobQuality_?150:100,jobQuality_);total+=jobChannels_*(.5+.25*double((n_+63)/64)+.5*double((hop_+63)/64))+4.*double((hop_+63)/64);costPerFrame_=total/double(std::max(1,hop_-int(jobAge_)-2));jobChannel_=0;jobStage_=JobStage::RepairBegin;}
     --units;++jobUnits_;break;}
    case JobStage::RepairBegin:repair_.begin(audio_[jobChannel_].data(),n_,regions_[jobChannel_].data(),counts_[jobChannel_],jobChannel_,context_,spline_,limit_,jobQuality_?150:100,jobQuality_);jobStage_=JobStage::Repair;--units;++jobUnits_;break;
    case JobStage::Repair:if(repair_.step(1)){jobOffset_=0;jobStage_=JobStage::Sanitize;}--units;++jobUnits_;break;
    case JobStage::Sanitize:{const unsigned c=jobChannel_;const int end=std::min(n_,int(jobOffset_)+64);for(int i=int(jobOffset_);i<end;++i)if(!std::isfinite(audio_[c][i]))audio_[c][i]=original_[c][i];jobOffset_=end;if(end==n_){jobOffset_=0;jobStage_=JobStage::Convert;}--units;++jobUnits_;break;}
    case JobStage::Convert:{const unsigned c=jobChannel_;const int end=std::min(hop_,int(jobOffset_)+64);for(int i=int(jobOffset_);i<end;++i){if(!std::isfinite(audio_[c][i]))audio_[c][i]=original_[c][i];const float y=float((jobDeclip_?audio_[c][i]:original_[c][i])*jobGain_);pending_[c][i]=std::isfinite(y)?y:0.f;}jobOffset_=end;if(end==hop_){if(++jobChannel_==jobChannels_){jobOffset_=0;jobStage_=JobStage::Limit;}else jobStage_=JobStage::RepairBegin;}--units;++jobUnits_;break;}
    case JobStage::Limit:{const auto count=uint32_t(std::min(hop_-int(jobOffset_),64));std::array<float*,2>p={pending_[0].data()+jobOffset_,pending_[1].data()+jobOffset_};limiter_.process(p.data(),jobChannels_,count);jobOffset_+=count;if(jobOffset_==unsigned(hop_)){meters_[3]=float(std::clamp(jobActivity_,0.,1.));jobStage_=JobStage::Done;}--units;++jobUnits_;break;}
    default:break;
   }
  }
 }
 struct Ramp{float target=0,step=0;uint32_t remaining=0;};
 void advance()noexcept{for(unsigned id=0;id<5;++id)if(rampMask_&(1u<<id)){auto&r=ramps_[id];values_[id]+=r.step;if(--r.remaining==0){values_[id]=r.target;rampMask_&=~(1u<<id);}}}
 enum class JobStage{Idle,Detect,RepairBegin,Repair,Sanitize,Convert,Limit,Done};
 double rate_=48000;int n_=0,hop_=0,context_=0,spline_=0,limit_=0,maximumRegion_=0;uint32_t latency_=0,fill_=0,read_=0,available_=0,channels_=0;size_t dryPosition_=0;
 declip::RecoveredDetector detector_;declip::RecoveredSegments segments_;recovered::RepairLoop repair_;declip::RecoveredLimiter limiter_;
 std::array<std::vector<double>,2>analysis_,audio_,original_;std::array<std::vector<float>,2>input_,output_,pending_,dry_;std::array<std::vector<Region>,2>regions_;std::array<int,2>counts_{};
 JobStage jobStage_=JobStage::Idle;unsigned jobChannels_=0,jobChannel_=0,jobOffset_=0,jobAge_=0;double costPerFrame_=1.,workCredit_=0.;bool jobType2_=false,jobDeclip_=true;int jobQuality_=0;double jobGain_=1.,jobActivity_=0.;uint64_t deadlineMisses_=0,jobUnits_=0,maximumJobUnits_=0;
 std::array<float,5>values_=defaults;std::array<Ramp,5>ramps_{};uint32_t rampMask_=0;bool bypass_=false;float bypassMix_=0,bypassStep_=0;
 std::array<float,4>meters_{};std::array<std::array<float,256>,2>waves_{};uint32_t meterTicks_=0,meterHop_=480,wavePosition_=0;double inputEnergy_=0,outputEnergy_=0;float waveIn_=0,waveOut_=0;
};
}

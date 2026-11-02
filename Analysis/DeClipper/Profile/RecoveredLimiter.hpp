#pragma once
// Reconstructed active ERA5 5.4.00 linked float output protection path.
// Evidence: func-44dd0.asm, func-461ac.asm, func-46a9c.asm, func-6a0cc.asm.
#include <array>
#include <vector>
#include <algorithm>
#include <cmath>
#include <cstdint>
namespace dayu::declip {
class RecoveredLimiter {
 struct Envelope {
  float rate=48000,attackMs=0,releaseMs=0,holdMs=0,attack=0,release=0,value=0;int hold=0;
  static float coefficient(float rate,float milliseconds)noexcept{
   const float samples=rate*std::fmax(milliseconds,0.f);const int count=std::max(1,int(std::ceil(double(samples)*.001)));
   return std::exp(float(-1.0023934841156006f/float(count)));
  }
  void prepare(float fs,float a,float r)noexcept{rate=fs;attackMs=a;releaseMs=r;holdMs=0;hold=0;value=0;attack=coefficient(rate,a);release=coefficient(rate,r);}
  void setRelease(float ms)noexcept{releaseMs=std::fmax(ms,0.f);release=coefficient(rate,releaseMs);}
  float process(float input,bool rms)noexcept {
   const float target=rms?input*input:std::abs(input);
   if(value>target){if(hold==0)value=target+(value-target)*release;else if(--hold<0)hold=0;}
   else {hold=int(std::ceil(double(rate*holdMs)*.001));value=target+(value-target)*attack;}
   value=std::fmax(value,0.f);return rms?std::sqrt(value):value;
  }
 };
public:
 void prepare(double rate){sampleRate=float(rate);delay=std::max(0,int(std::round((sampleRate*3.f)*float(.001))));period=delay+1;for(auto&v:audio)v.resize(period);reset();}
 void reset()noexcept{
  for(auto&v:audio)std::fill(v.begin(),v.end(),0.f);read=0;write=delay;counter=0;
  threshold=-9.999999974752427e-7f;ceiling=threshold;
  ceilingGain=::__exp10f(.05f*ceiling);inverseThreshold=::__exp10f(-.05f*threshold);floorGain=::__exp10f(.05f*threshold);cached=floorGain;
  // Original constructor initializes cached peak to the inverse threshold gain.
  cached=inverseThreshold;
  peakEnvelope.prepare(sampleRate,.05000000074505806f,70.f);
  rmsEnvelope.prepare(sampleRate,30.f,100.f);
  outputEnvelope.prepare(sampleRate,9.999999974752427e-7f,40.f);
 }
 int latencyFrames()const noexcept{return delay;}
 void process(float*const* buffers,unsigned channels,unsigned frames)noexcept{
  channels=std::min(channels,2u);
  for(unsigned i=0;i<frames;++i){
   float peak=0.f;for(unsigned c=0;c<channels;++c)peak=std::fmax(peak,std::abs(buffers[c][i]));
   std::array<float,2>delayed{};
   for(unsigned c=0;c<channels;++c){audio[c][write]=buffers[c][i];delayed[c]=audio[c][read];}
   if(++write==period)write=0;if(++read==period)read=0;
   const float candidate=std::fmax(peak,floorGain);
   if(++counter>=period || candidate>cached){counter=0;cached=candidate;}
   const float rms=rmsEnvelope.process(cached,true),average=peakEnvelope.process(cached,false);
   float ratio=2.f;if(rms!=0.f && average!=0.f){const float peakSquare=cached*cached,averageSquare=average*average,rmsSquare=rms*rms;ratio=std::fmax(peakSquare,averageSquare)/rmsSquare;}
   const float stage1=std::fmax(.009999999776482582f,(10.f+10.f)/ratio);
   const float stage2=std::fmax(1.f,(250.f+250.f)/ratio-stage1);
   outputEnvelope.setRelease(stage2);
   const float env=outputEnvelope.process(cached,false);
   const float envDB=std::log10(env)*20.f;
   const float correction=envDB>threshold?(threshold-envDB)*.05f:0.f;
   const float gain=(::__exp10f(correction)*inverseThreshold)*ceilingGain;
   for(unsigned c=0;c<channels;++c)buffers[c][i]=std::fmax(std::fmin(delayed[c]*gain,ceilingGain),-ceilingGain);
  }
 }
private:
 float sampleRate=48000,threshold=0,ceiling=0,ceilingGain=1,inverseThreshold=1,floorGain=1,cached=1;int delay=144,period=145,read=0,write=144,counter=0;
 std::array<std::vector<float>,2>audio;Envelope peakEnvelope,rmsEnvelope,outputEnvelope;
};
}

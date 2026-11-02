#include <array>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>
#include <fstream>
#include <iostream>
#include <Accelerate/Accelerate.h>
#define private public
#include "TraceSnapshot/ERA5DeClipperCore.hpp"
#undef private
int main(int argc,char**argv){if(argc!=5)return 2;std::ifstream in(argv[1],std::ios::binary|std::ios::ate);const auto frames=size_t(in.tellg())/8;in.seekg(0);std::vector<float>source(frames*2);in.read(reinterpret_cast<char*>(source.data()),source.size()*4);const std::string prefix=argv[2];std::ofstream windows(prefix+"-windows.jsonl");dayu::ERA5DeClipperCore core;core.prepare(48000);core.setParameter(0,std::atoi(argv[3]));core.setParameter(2,std::atoi(argv[4]));std::vector<float>output(frames*2),pre(frames*2);std::vector<unsigned char>candidate(frames),repaired(frames),filled(frames);float il=0,ir=0,ol=0,orr=0;float*pi[2]={&il,&ir},*po[2]={&ol,&orr};uint64_t k=0,detected=0,totalDetectedLength=0,completed=0;int maxRegion=0;bool captured=false,detCaptured=false;
for(size_t t=0;t<frames+core.latencyFrames();++t){il=t<frames?source[t*2]:0;ir=t<frames?source[t*2+1]:0;core.process(pi,po,2,1);if(t>=core.latencyFrames()){output[(t-core.latencyFrames())*2]=ol;output[(t-core.latencyFrames())*2+1]=orr;}
if(core.jobStage_==dayu::ERA5DeClipperCore::JobStage::Detect&&core.jobAge_==0){++k;captured=false;detCaptured=false;}
const int64_t start=int64_t(k*core.hop_)-core.n_;
if(!detCaptured&&core.jobStage_==dayu::ERA5DeClipperCore::JobStage::RepairBegin){detCaptured=true;for(int r=0;r<core.segments_.count();++r){const auto&v=core.segments_.data()[r];++detected;totalDetectedLength+=v.end-v.start+1;maxRegion=std::max(maxRegion,v.end-v.start+1);for(int i=v.start;i<=v.end;++i)if(start+i>=0&&start+i<int64_t(frames))candidate[start+i]=1;}const auto&d=core.detector_.results[0];windows<<"{\"window\":"<<k<<",\"sourceStart\":"<<start<<",\"detectedRegions\":"<<core.segments_.count()<<",\"rollingRegions\":"<<core.counts_[0]<<",\"positive\":"<<d.positive<<",\"negative\":"<<d.negative<<",\"positiveTolerance\":"<<d.positiveTolerance<<",\"negativeTolerance\":"<<d.negativeTolerance<<",\"extent\":"<<d.extent<<"}\n";}
if(!captured&&core.jobStage_==dayu::ERA5DeClipperCore::JobStage::Done){captured=true;++completed;for(int i=0;i<core.hop_;++i)if(start+i>=0&&start+i<int64_t(frames)){filled[start+i]=1;for(unsigned c=0;c<2;++c)pre[(start+i)*2+c]=float(core.audio_[c][i]);}for(int r=0;r<core.counts_[0];++r){auto&v=core.regions_[0][r];if(v.status==4)for(int i=std::max(v.start,0);i<std::min(v.end+1,core.hop_);++i)if(start+i>=0&&start+i<int64_t(frames))repaired[start+i]=1;}}
}
for(auto [suffix,ptr,bytes]:{std::tuple{"-output.f32",static_cast<const void*>(output.data()),output.size()*4},std::tuple{"-pre-limiter.f32",static_cast<const void*>(pre.data()),pre.size()*4},std::tuple{"-candidate-mask.u8",static_cast<const void*>(candidate.data()),candidate.size()},std::tuple{"-repaired-mask.u8",static_cast<const void*>(repaired.data()),repaired.size()}}){std::ofstream f(prefix+suffix,std::ios::binary);f.write(static_cast<const char*>(ptr),bytes);}
std::cout<<"{\"frames\":"<<frames<<",\"completedWindows\":"<<completed<<",\"detectedRegions\":"<<detected<<",\"totalDetectedRegionLength\":"<<totalDetectedLength<<",\"maxDetectedRegion\":"<<maxRegion<<",\"candidateCoverageSamples\":"<<std::count(candidate.begin(),candidate.end(),1)<<",\"finalStatus4Samples\":"<<std::count(repaired.begin(),repaired.end(),1)<<",\"filledSamples\":"<<std::count(filled.begin(),filled.end(),1)<<",\"predictions\":"<<dayu::trace::predictions<<",\"invalidPolynomial\":"<<dayu::trace::invalidPolynomial<<",\"dualRepairs\":"<<dayu::trace::dualCalls<<",\"geometryFailures\":"<<dayu::trace::geometryFailures<<",\"dualEnergyFallbacks\":"<<dayu::trace::dualEnergyFallbacks<<",\"finalEnergyFallbacks\":"<<dayu::trace::finalEnergyFallbacks<<",\"deadlineMisses\":"<<core.deadlineMisses()<<"}\n";}

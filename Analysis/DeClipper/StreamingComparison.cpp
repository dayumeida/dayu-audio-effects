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
#include "ERA5DeClipperCore.hpp"
#undef private
static float sample(unsigned t,double rate){const double sec=double(t)/rate;const double clean=.7*std::sin(2*M_PI*997*sec)+.2*std::sin(2*M_PI*301*sec);if(sec<.5)return float(clean*.4);if(sec<1.5)return float(std::max(-.35,std::min(.35,clean)));if(sec<2.5)return float(std::max(-.15,std::min(.25,clean)));return float(clean*.4);}
int main(int argc,char**argv){if(argc!=4)return 2;FILE*f=std::fopen(argv[1],"rb");if(!f)return 2;dayu::ERA5DeClipperCore core;core.prepare(48000);core.setParameter(2,std::atoi(argv[2]));core.setParameter(0,std::atoi(argv[3]));std::vector<float>in(core.hop_),out(core.hop_);float*pi[2]={in.data(),in.data()},*po[2]={out.data(),out.data()};int h[9];unsigned call=0;bool failed=false;
while(std::fread(h,sizeof(h),1,f)==1){int n=h[0],count=h[1],ch=h[2],pn=h[8];std::vector<double>x(n),expected(n),before(pn),after(pn);std::vector<dayu::recovered::RepairLoop::Region>reg(count),regAfter(count);std::fread(x.data(),8,n,f);std::fread(expected.data(),8,n,f);std::fread(before.data(),8,pn,f);std::fread(after.data(),8,pn,f);std::fread(reg.data(),12,count,f);std::fread(regAfter.data(),12,count,f);
if(ch==0){for(int i=0;i<core.hop_;++i)in[i]=sample(call*core.hop_/2+i,48000);core.process(pi,po,2,core.hop_);}
unsigned different=0,rd=0,pd=0;int first=-1;double err=0;
for(int i=0;i<n;++i)if(std::memcmp(&core.audio_[ch][i],&expected[i],8)){++different;if(first<0)first=i;err=std::max(err,std::abs(core.audio_[ch][i]-expected[i]));}
for(int i=0;i<pn;++i)if(std::memcmp(core.repair_.polynomial(ch)+i,&after[i],8))++pd;
if(count!=core.counts_[ch])rd=1000000;else for(int i=0;i<count;++i)if(std::memcmp(&core.regions_[ch][i],&regAfter[i],12))++rd;
if(different||rd||pd){std::cout<<"call "<<call<<" window "<<call/2<<" ch "<<ch<<" different "<<different<<" first "<<first<<" error "<<err<<" region "<<rd<<" polynomial "<<pd<<"\n";failed=true;if(first>=0){for(int i=std::max(0,first-2);i<std::min(n,first+3);++i)std::cout<<i<<" "<<std::hexfloat<<core.audio_[ch][i]<<" "<<expected[i]<<std::defaultfloat<<"\n";}break;}++call;}
std::cout<<"Checked "<<call<<" calls; failed="<<failed<<"\n";return failed;}

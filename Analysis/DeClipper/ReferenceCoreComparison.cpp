#include "ERA5DeClipperReferenceCore.hpp"
#include <fstream>
#include <iostream>
#include <cmath>
#include <chrono>
#include <new>
static bool tracking=false;static unsigned allocations=0;
void*operator new(std::size_t n){if(tracking)++allocations;if(void*p=std::malloc(n))return p;throw std::bad_alloc();}
void*operator new[](std::size_t n){return ::operator new(n);}void operator delete(void*p)noexcept{std::free(p);}void operator delete[](void*p)noexcept{std::free(p);}
static float sample(unsigned t,double rate){const double sec=double(t)/rate;const double clean=.7*std::sin(2*M_PI*997*sec)+.2*std::sin(2*M_PI*301*sec);if(sec<.5)return float(clean*.4);if(sec<1.5)return float(std::max(-.35,std::min(.35,clean)));if(sec<2.5)return float(std::max(-.15,std::min(.25,clean)));return float(clean*.4);}
int main(int argc,char**argv){const int type=argc>2?std::atoi(argv[2]):0,quality=argc>3?std::atoi(argv[3]):0;const double rate=argc>4?std::atof(argv[4]):48000;const int chunk=argc>5?std::atoi(argv[5]):512;dayu::ERA5DeClipperReferenceCore core;core.prepare(rate);core.setParameter(2,type);core.setParameter(0,quality);std::array<std::vector<float>,2>in,out;for(auto&v:in)v.resize(chunk);for(auto&v:out)v.resize(chunk);float*pi[2]={in[0].data(),in[1].data()},*po[2]={out[0].data(),out[1].data()};std::ofstream file(argv[1],std::ios::binary);std::vector<double>timing;timing.reserve(10000);unsigned first=~0u;
for(unsigned t=0;t<unsigned(rate*4);t+=chunk){unsigned n=std::min(unsigned(chunk),unsigned(rate*4)-t);for(unsigned i=0;i<n;++i)pi[0][i]=pi[1][i]=sample(t+i,rate);auto start=std::chrono::steady_clock::now();tracking=true;core.process(pi,po,2,n);tracking=false;timing.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());file.write(reinterpret_cast<char*>(po[0]),n*4);for(unsigned i=0;i<n;++i)if(first==~0u&&std::abs(po[0][i])>1e-7)first=t+i;}
std::sort(timing.begin(),timing.end());double sum=0;for(auto t:timing)sum+=t;std::cout<<"{\"firstNonzero\":"<<first<<",\"latency\":"<<core.latencyFrames()<<",\"allocations\":"<<allocations<<",\"totalMilliseconds\":"<<sum<<",\"p99Milliseconds\":"<<timing[size_t(.99*(timing.size()-1))]<<",\"maxMilliseconds\":"<<timing.back()<<"}\n";}

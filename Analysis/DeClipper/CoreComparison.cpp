#include "ERA5DeClipperCore.hpp"
#include <fstream>
#include <iostream>
#include <cmath>
#include <chrono>
#include <new>
#include <time.h>
#include <pthread.h>
#include <sys/qos.h>
static double threadMilliseconds(){timespec t{};clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t);return t.tv_sec*1000.+t.tv_nsec*.000001;}
static bool tracking=false;static unsigned allocations=0;
void*operator new(std::size_t n){if(tracking)++allocations;if(void*p=std::malloc(n))return p;throw std::bad_alloc();}
void*operator new[](std::size_t n){return ::operator new(n);}void operator delete(void*p)noexcept{std::free(p);}void operator delete[](void*p)noexcept{std::free(p);}
static float sample(unsigned t,double rate){const double sec=double(t)/rate;const double clean=.7*std::sin(2*M_PI*997*sec)+.2*std::sin(2*M_PI*301*sec);if(sec<.5)return float(clean*.4);if(sec<1.5)return float(std::max(-.35,std::min(.35,clean)));if(sec<2.5)return float(std::max(-.15,std::min(.25,clean)));return float(clean*.4);}
int main(int argc,char**argv){pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);const int type=argc>2?std::atoi(argv[2]):0,quality=argc>3?std::atoi(argv[3]):0;const double rate=argc>4?std::atof(argv[4]):48000;const int chunk=argc>5?std::atoi(argv[5]):512;dayu::ERA5DeClipperCore core;core.prepare(rate);core.setParameter(2,type);core.setParameter(0,quality);std::array<std::vector<float>,2>in,out;for(auto&v:in)v.resize(chunk);for(auto&v:out)v.resize(chunk);float*pi[2]={in[0].data(),in[1].data()},*po[2]={out[0].data(),out[1].data()};std::ofstream file(argv[1],std::ios::binary);std::vector<double>timing;timing.reserve(10000);std::vector<double>cpuTiming;cpuTiming.reserve(10000);unsigned first=~0u;
for(unsigned t=0;t<unsigned(rate*4);t+=chunk){unsigned n=std::min(unsigned(chunk),unsigned(rate*4)-t);for(unsigned i=0;i<n;++i)pi[0][i]=pi[1][i]=sample(t+i,rate);auto start=std::chrono::steady_clock::now();const double cpuStart=threadMilliseconds();tracking=true;core.process(pi,po,2,n);tracking=false;cpuTiming.push_back(threadMilliseconds()-cpuStart);timing.push_back(std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count());file.write(reinterpret_cast<char*>(po[0]),n*4);for(unsigned i=0;i<n;++i)if(first==~0u&&std::abs(po[0][i])>1e-7)first=t+i;}
std::sort(timing.begin(),timing.end());std::sort(cpuTiming.begin(),cpuTiming.end());double sum=0,cpuSum=0;for(auto t:timing)sum+=t;for(auto t:cpuTiming)cpuSum+=t;std::cout<<"{\"firstNonzero\":"<<first<<",\"latency\":"<<core.latencyFrames()<<",\"deadlineMisses\":"<<core.deadlineMisses()<<",\"maximumJobUnits\":"<<core.maximumJobUnits()<<",\"allocations\":"<<allocations<<",\"totalMilliseconds\":"<<sum<<",\"p99Milliseconds\":"<<timing[size_t(.99*(timing.size()-1))]<<",\"maxMilliseconds\":"<<timing.back()<<",\"cpuTotalMilliseconds\":"<<cpuSum<<",\"cpuP99Milliseconds\":"<<cpuTiming[size_t(.99*(cpuTiming.size()-1))]<<",\"cpuMaxMilliseconds\":"<<cpuTiming.back()<<"}\n";}

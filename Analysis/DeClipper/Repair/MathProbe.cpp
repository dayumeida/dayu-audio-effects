#include <Accelerate/Accelerate.h>
#include <vector>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <chrono>
#include "RecoveredLPC.hpp"
static uint64_t seed=0x100385832963ull;
static double randomValue(){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;return double(seed&0x1fffffffffffffull)/double(0x10000000000000ull)-1.0;}
int main(){std::vector<double>a(1600),b(1600),c(1600),d(1600);unsigned diff=0;
 for(unsigned t=0;t<1000;++t){double k=randomValue();for(unsigned i=0;i<a.size();++i)a[i]=randomValue();
 vDSP_vsdivD(a.data(),1,&k,b.data(),1,a.size());
 for(unsigned i=0;i<a.size();++i){c[i]=a[i]*(1.0/k);if(std::memcmp(&b[i],&c[i],8))++diff;}}
 double x;vDSP_dotprD(a.data(),1,a.data(),1,&x,762);std::printf("divisionDifferences=%u dot=%.17g\n",diff,x);
 unsigned dotDiff=0;double values[6];
 for(unsigned t=0;t<10000;++t){const unsigned n=1+t%a.size();for(unsigned i=0;i<n;++i){a[i]=randomValue();b[i]=randomValue();}
  vDSP_dotprD(a.data(),1,a.data(),1,&values[0],n);vDSP_dotprD(a.data(),1,b.data(),1,&values[1],n);vDSP_dotprD(b.data(),1,b.data(),1,&values[2],n);
  dayu::recovered::LPC::combinedDot(a.data(),b.data(),n,values[3],values[4],values[5]);
  for(unsigned j=0;j<3;++j)if(std::memcmp(&values[j],&values[j+3],8))++dotDiff;
 }
 auto start=std::chrono::steady_clock::now();for(unsigned t=0;t<100000;++t){vDSP_dotprD(a.data(),1,a.data(),1,&values[0],762);vDSP_dotprD(a.data(),1,b.data(),1,&values[1],762);vDSP_dotprD(b.data(),1,b.data(),1,&values[2],762);}auto middle=std::chrono::steady_clock::now();
 for(unsigned t=0;t<100000;++t)dayu::recovered::LPC::combinedDot(a.data(),b.data(),762,values[3],values[4],values[5]);auto end=std::chrono::steady_clock::now();
 std::printf("dotDifferences=%u vDSPms=%.5f fusedms=%.5f sink=%.17g\n",dotDiff,std::chrono::duration<double,std::milli>(middle-start).count(),std::chrono::duration<double,std::milli>(end-middle).count(),values[3]);
}

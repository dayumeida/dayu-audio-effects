#include "RecoveredRepairLoop.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>
#include <cstring>
static bool tracking=false;static unsigned long allocations=0;
void*operator new(std::size_t n){if(tracking)++allocations;if(void*p=std::malloc(n))return p;throw std::bad_alloc();}
void*operator new[](std::size_t n){return ::operator new(n);}
void operator delete(void*p)noexcept{std::free(p);}void operator delete[](void*p)noexcept{std::free(p);}
int main(int argc,char**argv){
 if(argc<2||argc>3)return 2;FILE*f=std::fopen(argv[1],"rb");if(!f)return 2;
 const unsigned budget=argc==3?unsigned(std::strtoul(argv[2],nullptr,10)):0;
 dayu::recovered::RepairLoop loop;loop.prepare(32768,150);loop.setReferenceHeapTail(true);
 int h[9];unsigned call=0;bool failed=false;std::printf("[\n");
 while(std::fread(h,sizeof(h),1,f)==1){
  int n=h[0],count=h[1],ch=h[2],pn=h[8];
  std::vector<double>x(n),expected(n),before(pn),after(pn);
  std::vector<dayu::recovered::RepairLoop::Region>reg(count),regAfter(count);
  std::fread(x.data(),8,n,f);std::fread(expected.data(),8,n,f);std::fread(before.data(),8,pn,f);std::fread(after.data(),8,pn,f);std::fread(reg.data(),12,count,f);std::fread(regAfter.data(),12,count,f);
  loop.loadPolynomial(ch,before.data(),pn);allocations=0;tracking=true;std::uint64_t steps=0,upper=0;double estimated=0.0,spent=0.0;
  if(!budget)loop.process(x.data(),n,reg.data(),count,ch,h[3],h[4],h[5],h[6],h[7]);
  else {loop.begin(x.data(),n,reg.data(),count,ch,h[3],h[4],h[5],h[6],h[7]);upper=loop.workUnitsUpperBound();estimated=loop.estimatedCost();do{++steps;spent+=loop.nextCost();}while(!loop.step(budget));}
  tracking=false;
  double err=0,pe=0;unsigned different=0,rd=0;std::size_t first=n;
  for(int i=0;i<n;++i)if(std::memcmp(&x[i],&expected[i],8)){++different;if(first==std::size_t(n))first=i;err=std::max(err,std::abs(x[i]-expected[i]));}
  for(int i=0;i<pn;++i)pe=std::max(pe,std::abs(loop.polynomial(ch)[i]-after[i]));
  for(int i=0;i<count;++i)if(std::memcmp(&reg[i],&regAfter[i],12))++rd;
  failed=failed||err!=0||pe!=0||rd!=0||allocations!=0;
  std::printf("%s{\"call\":%u,\"channel\":%d,\"outputError\":%.17g,\"different\":%u,\"firstDifference\":%zu,\"polyError\":%.17g,\"regionDifferences\":%u,\"allocations\":%lu,\"steps\":%llu,\"workUnitsUpperBound\":%llu,\"estimatedCost\":%.17g,\"spentCost\":%.17g}\n",call?",":"",call,ch,err,different,first,pe,rd,allocations,(unsigned long long)steps,(unsigned long long)upper,estimated,spent);++call;
 }
 std::printf("]\n");std::fclose(f);return failed?1:0;
}

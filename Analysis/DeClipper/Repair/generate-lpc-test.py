from pathlib import Path
import json
r=Path(__file__).parent;j=json.loads((r/'lpc-runtime-calls.json').read_text())
p=['#include "RecoveredLPC.hpp"','#include <cstdio>','#include <cstdlib>','#include <new>','#include <atomic>','#include <cstring>','static std::atomic<unsigned> allocations{0}; static bool track=false;','void* operator new(std::size_t n){if(track)++allocations; if(void*p=std::malloc(n))return p;throw std::bad_alloc();}','void operator delete(void*p)noexcept{std::free(p);}','int main(){dayu::recovered::LPC lpc;lpc.prepare(16384,150,16384);std::printf("[\\n");']
for i,d in enumerate(j):
 def arr(name,x):return 'double '+name+'[]={'+','.join(float(v).hex() for v in x)+'};'
 p+=['{',arr('storage',[0]+d['input']+[0]),arr('expectedOutput',d['output']),arr('expectedPoly',d['lpc0x0']),arr('expectedReflection',d['lpc0x20'])]
 prefix=(int(d['inputAddress'],16)>>3)&1
 p+=['double*context=storage+'+str(prefix)+';']
 # Need move data to requested prefix, independent stack base alignment (alignas next pass).
 p+=['std::memmove(context,storage+1,sizeof(double)*'+str(d['inputLen'])+');', 'double mean=dayu::recovered::LPC::armMean(context,'+str(d['inputLen'])+');','track=true; bool valid=lpc.predict(context,'+str(d['inputLen'])+','+str(d['predictLen'])+','+str(d['order'])+','+str(d['estimate'])+');track=false;','double errOutput=0,errPoly=0,errReflection=0;']
 p+=['for(size_t k=0;k<sizeof(expectedOutput)/8;++k)errOutput=std::max(errOutput,std::abs(lpc.output()[k]-expectedOutput[k]));','for(size_t k=0;k<sizeof(expectedPoly)/8;++k)errPoly=std::max(errPoly,std::abs(lpc.polynomial()[k]-expectedPoly[k]));','for(size_t k=0;k<sizeof(expectedReflection)/8;++k)errReflection=std::max(errReflection,std::abs(lpc.reflection()[k]-expectedReflection[k]));']
 p+=['std::printf("'+(',' if i else '')+'{\\\"call\\\":'+str(i)+',\\\"valid\\\":%s,\\\"meanError\\\":%.17g,\\\"outputError\\\":%.17g,\\\"polynomialError\\\":%.17g,\\\"reflectionError\\\":%.17g,\\\"allocations\\\":%u}\\n",valid?"true":"false",mean-('+float(d['mean']).hex()+'),errOutput,errPoly,errReflection,allocations.load());','}']
p+=['std::printf("]\\n");}']
(r/'LPCComparison.cpp').write_text('\n'.join(p))

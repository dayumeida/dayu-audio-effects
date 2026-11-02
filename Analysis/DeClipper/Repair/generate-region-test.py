from pathlib import Path
import json
r=Path(__file__).parent
j=json.loads((r/'dual-runtime-calls.json').read_text());sp=json.loads((r/'spline-runtime-calls.json').read_text())
def arr(name,x):return 'double '+name+'[]={'+','.join(float(v).hex() for v in x)+'};'
p=['#include "RecoveredDualPrediction.hpp"','#include <cstdio>','int main(){dayu::recovered::DualPrediction dual;dual.prepare(16384,150);dayu::recovered::BesselSpline spline;spline.prepare(16384);std::printf("[\\n");']
for i,d in enumerate(j):
 p+=['{',arr('input',d['input']),arr('expected',d['output']),arr('before',d['polynomialBefore']),arr('after',d['polynomialAfter']),arr('f',d['0x1b0']),arr('b',d['0x1c0']),arr('fw',d['0x1d0']),arr('bw',d['0x1e0'])]
 l=d['left'];length=d['end']-d['start']+1
 p+=['dual.loadPolynomial(before,sizeof(before)/8);int result=dual.repair(input,sizeof(input)/8,'+str(l)+','+str(l+length-1)+','+str(d['context'])+','+str(d['order'])+','+str(d['primary'])+','+str(d['secondary'])+');double err=0,ep=0,ef=0,eb=0,efw=0,ebw=0;','for(size_t k=0;k<sizeof(input)/8;++k)err=std::max(err,std::abs(input[k]-expected[k]));for(size_t k=0;k<sizeof(after)/8;++k)ep=std::max(ep,std::abs(dual.polynomial()[k]-after[k]));','for(size_t k=0;k<sizeof(f)/8;++k){ef=std::max(ef,std::abs(dual.forward()[k]-f[k]));eb=std::max(eb,std::abs(dual.backward()[k]-b[k]));efw=std::max(efw,std::abs(dual.forwardWeights()[k]-fw[k]));ebw=std::max(ebw,std::abs(dual.backwardWeights()[k]-bw[k]));}', 'std::printf("'+(',' if i else '')+'{\\\"type\\\":\\\"dual\\\",\\\"call\\\":'+str(i)+',\\\"return\\\":%d,\\\"outputError\\\":%.17g,\\\"polyError\\\":%.17g,\\\"forwardError\\\":%.17g,\\\"backwardError\\\":%.17g,\\\"fwError\\\":%.17g,\\\"bwError\\\":%.17g}\\n",result,err,ep,ef,eb,efw,ebw);','}']
for i,d in enumerate(sp):
 p+=['{',arr('x',d['x']),arr('y',d['y']),arr('expected',d['slopes']),'spline.build(x,y,sizeof(x)/8);double err=0;for(size_t k=0;k<sizeof(x)/8;++k)err=std::max(err,std::abs(spline.slopes()[k]-expected[k]));','std::printf(",{\\\"type\\\":\\\"spline\\\",\\\"call\\\":'+str(i)+',\\\"slopeError\\\":%.17g}\\n",err);','}']
p+=['std::printf("]\\n");}'];(r/'RegionComparison.cpp').write_text('\n'.join(p))

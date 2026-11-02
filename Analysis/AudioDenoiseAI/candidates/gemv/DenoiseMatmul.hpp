#pragma once
#include <Accelerate/Accelerate.h>
namespace dayu_denoise {inline void matmul(const float*A,const float*B,float*C,int M,int N,int K)noexcept{
const auto previous=BLASGetThreading();BLASSetThreading(BLAS_THREADING_SINGLE_THREADED);
for(int col=0;col<N;++col)cblas_sgemv(CblasRowMajor,CblasNoTrans,M,K,1,A,K,B+col,N,0,C+col,N);
BLASSetThreading(previous);
}}

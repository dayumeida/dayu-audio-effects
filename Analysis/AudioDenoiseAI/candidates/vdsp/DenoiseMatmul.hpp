#pragma once
#include <Accelerate/Accelerate.h>
namespace dayu_denoise {inline void matmul(const float*A,const float*B,float*C,int M,int N,int K)noexcept{vDSP_mmul(A,1,B,1,C,1,M,N,K);}}

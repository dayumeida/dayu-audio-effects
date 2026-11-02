#pragma once
#include <algorithm>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif
namespace dayu_denoise {
// Single-threaded row-major SGEMM with caller-owned storage. B and C widths are
// multiples of four; no heap, system BLAS dispatch, workspace, locks or threads.
inline void matmul(const float*A,const float*B,float*C,int M,int N,int K)noexcept{
#if defined(__aarch64__)
 int row=0;
 for(;row+3<M;row+=4){
  const float*a0=A+row*K,*a1=a0+K,*a2=a1+K,*a3=a2+K;
  int col=0;
  for(;col+7<N;col+=8){
   float32x4_t c00=vdupq_n_f32(0),c01=c00,c10=c00,c11=c00,c20=c00,c21=c00,c30=c00,c31=c00;
   const float*b=B+col;
   for(int k=0;k<K;++k,b+=N){const auto b0=vld1q_f32(b),b1=vld1q_f32(b+4);
    c00=vfmaq_n_f32(c00,b0,a0[k]);c01=vfmaq_n_f32(c01,b1,a0[k]);
    c10=vfmaq_n_f32(c10,b0,a1[k]);c11=vfmaq_n_f32(c11,b1,a1[k]);
    c20=vfmaq_n_f32(c20,b0,a2[k]);c21=vfmaq_n_f32(c21,b1,a2[k]);
    c30=vfmaq_n_f32(c30,b0,a3[k]);c31=vfmaq_n_f32(c31,b1,a3[k]);
   }
   vst1q_f32(C+(row+0)*N+col,c00);vst1q_f32(C+(row+0)*N+col+4,c01);
   vst1q_f32(C+(row+1)*N+col,c10);vst1q_f32(C+(row+1)*N+col+4,c11);
   vst1q_f32(C+(row+2)*N+col,c20);vst1q_f32(C+(row+2)*N+col+4,c21);
   vst1q_f32(C+(row+3)*N+col,c30);vst1q_f32(C+(row+3)*N+col+4,c31);
  }
  if(col<N){float32x4_t c0=vdupq_n_f32(0),c1=c0,c2=c0,c3=c0;const float*b=B+col;
   for(int k=0;k<K;++k,b+=N){const auto x=vld1q_f32(b);c0=vfmaq_n_f32(c0,x,a0[k]);c1=vfmaq_n_f32(c1,x,a1[k]);c2=vfmaq_n_f32(c2,x,a2[k]);c3=vfmaq_n_f32(c3,x,a3[k]);}
   vst1q_f32(C+(row+0)*N+col,c0);vst1q_f32(C+(row+1)*N+col,c1);vst1q_f32(C+(row+2)*N+col,c2);vst1q_f32(C+(row+3)*N+col,c3);
  }
 }
 for(;row<M;++row){for(int col=0;col<N;col+=4){auto c=vdupq_n_f32(0);const float*b=B+col;for(int k=0;k<K;++k,b+=N)c=vfmaq_n_f32(c,vld1q_f32(b),A[row*K+k]);vst1q_f32(C+row*N+col,c);}}
#else
 std::fill(C,C+M*N,0.f);
 for(int row=0;row<M;++row)for(int k=0;k<K;++k)for(int col=0;col<N;++col)C[row*N+col]+=A[row*K+k]*B[k*N+col];
#endif
}
}

#pragma once
#include "DenoiseMatmul.hpp"
#include <Accelerate/Accelerate.h>
#include <cstdlib>
#include <cstring>
#include <utility>
namespace dayu_denoise {
// BNNS generic matrix multiplication accepts caller-owned workspace and one
// worker thread. Its current single-output GEMV path ignores that workspace;
// route that small final layer through the allocation-free NEON kernel.
class MatrixEngine {
public:
 MatrixEngine()=default;
 MatrixEngine(const MatrixEngine&)=delete;
 MatrixEngine&operator=(const MatrixEngine&)=delete;
 MatrixEngine(MatrixEngine&&o)noexcept:workspace_(std::exchange(o.workspace_,nullptr)){}
 MatrixEngine&operator=(MatrixEngine&&o)noexcept{if(this!=&o){std::free(workspace_);workspace_=std::exchange(o.workspace_,nullptr);}return *this;}
 ~MatrixEngine(){std::free(workspace_);}
 static ssize_t size(int M,int N,int K)noexcept {
  if(M==1)return 0;
  auto a=descriptor(nullptr,M,K),b=descriptor(nullptr,K,N),c=descriptor(nullptr,M,N);
  const BNNSFilterParameters parameters{0,1,nullptr,nullptr};
  return BNNSMatMulWorkspaceSize(false,false,1,&a,&b,&c,&parameters);
 }
 void disable()noexcept{std::free(workspace_);workspace_=nullptr;}
 bool prepare(size_t bytes){
  std::free(workspace_);workspace_=nullptr;
  if(posix_memalign(&workspace_,64,std::max(size_t(64),bytes)))return false;
  std::memset(workspace_,0,std::max(size_t(64),bytes));return true;
 }
 void multiply(const float*A,const float*B,float*C,int M,int N,int K)noexcept {
  if(M==1||!workspace_){matmul(A,B,C,M,N,K);return;}
  auto a=descriptor(const_cast<float*>(A),M,K),b=descriptor(const_cast<float*>(B),K,N),c=descriptor(C,M,N);
  const BNNSFilterParameters parameters{0,1,nullptr,nullptr};
  if(BNNSMatMul(false,false,1,&a,&b,&c,workspace_,&parameters))matmul(A,B,C,M,N,K);
 }
private:
 static BNNSNDArrayDescriptor descriptor(void*p,int rows,int cols)noexcept {
  BNNSNDArrayDescriptor d{};d.layout=BNNSDataLayoutRowMajorMatrix;d.size[0]=cols;d.size[1]=rows;d.data=p;d.data_type=BNNSDataTypeFloat32;return d;
 }
 void*workspace_=nullptr;
};
}

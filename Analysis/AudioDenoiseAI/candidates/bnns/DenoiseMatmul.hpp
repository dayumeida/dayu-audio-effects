#pragma once
#include <Accelerate/Accelerate.h>
#include <cstdlib>
#include <cstdio>
#include <algorithm>
namespace dayu_denoise {
inline BNNSNDArrayDescriptor desc(void*p,int rows,int cols){BNNSNDArrayDescriptor d{};d.layout=BNNSDataLayoutRowMajorMatrix;d.size[0]=cols;d.size[1]=rows;d.data=p;d.data_type=BNNSDataTypeFloat32;return d;}
class MatrixEngine{
public:
 ~MatrixEngine(){std::free(workspace);}
 static size_t size(int M,int N,int K){auto a=desc(nullptr,M,K),b=desc(nullptr,K,N),c=desc(nullptr,M,N);BNNSFilterParameters p{0,1,nullptr,nullptr};const auto n=BNNSMatMulWorkspaceSize(false,false,1,&a,&b,&c,&p);if(n<0){fprintf(stderr,"badBNNSshape %d,%d,%d: %ld\n",M,N,K,n);abort();}return size_t(n);}
 void prepare(size_t bytes){std::free(workspace);if(posix_memalign(&workspace,64,std::max(size_t(64),bytes)))abort();}
 void multiply(const float*A,const float*B,float*C,int M,int N,int K)noexcept{auto a=desc(const_cast<float*>(A),M,K),b=desc(const_cast<float*>(B),K,N),c=desc(C,M,N);BNNSFilterParameters p{0,1,nullptr,nullptr};int status=BNNSMatMul(false,false,1,&a,&b,&c,workspace,&p);if(status){fprintf(stderr,"badBNNSmultiply %d\n",status);abort();}}
private:void*workspace=nullptr;
};
}

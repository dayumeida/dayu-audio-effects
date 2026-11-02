#pragma once
#include <Accelerate/Accelerate.h>
#include <cstdlib>
#include <cstdio>
#include <algorithm>
#include <pthread.h>
#include <cerrno>
#include <cstdint>
namespace dayu_denoise {inline int currentM=0,currentN=0,currentK=0;
inline BNNSNDArrayDescriptor desc(void*p,int rows,int cols){BNNSNDArrayDescriptor d{};d.layout=BNNSDataLayoutRowMajorMatrix;d.size[0]=cols;d.size[1]=rows;d.data=p;d.data_type=BNNSDataTypeFloat32;return d;}
class MatrixEngine{
public:
 ~MatrixEngine(){std::free(workspace);std::free(arena);}
 static size_t size(int M,int N,int K){auto a=desc(nullptr,M,K),b=desc(nullptr,K,N),c=desc(nullptr,M,N);BNNSFilterParameters p{0,1,nullptr,nullptr};const auto n=BNNSMatMulWorkspaceSize(false,false,1,&a,&b,&c,&p);if(n<0){fprintf(stderr,"badBNNSshape %d,%d,%d: %ld\n",M,N,K,n);abort();}return size_t(n);}
 void prepare(size_t bytes){key();std::free(workspace);std::free(arena);if(posix_memalign(&workspace,64,std::max(size_t(64),bytes)))abort();arenaCapacity=4*1024*1024;if(posix_memalign(&arena,64,arenaCapacity))abort();}
 void multiply(const float*A,const float*B,float*C,int M,int N,int K)noexcept{currentM=M;currentN=N;currentK=K;auto a=desc(const_cast<float*>(A),M,K),b=desc(const_cast<float*>(B),K,N),c=desc(C,M,N);offset=0;void*previous=pthread_getspecific(key());pthread_setspecific(key(),this);BNNSFilterParameters p{0,1,allocate,release};int status=BNNSMatMul(false,false,1,&a,&b,&c,workspace,&p);pthread_setspecific(key(),previous);if(status){fprintf(stderr,"badBNNSmultiply %d peak%zu\n",status,offset);abort();}}
private:
 static pthread_key_t key(){static pthread_key_t k=[](){pthread_key_t x;pthread_key_create(&x,nullptr);return x;}();return k;}
 static int allocate(void**out,size_t alignment,size_t size){auto*self=static_cast<MatrixEngine*>(pthread_getspecific(key()));if(!self)return ENOMEM;const uintptr_t begin=(reinterpret_cast<uintptr_t>(self->arena)+self->offset+alignment-1)&~(alignment-1);const size_t end=begin-reinterpret_cast<uintptr_t>(self->arena)+size;if(end>self->arenaCapacity){*out=nullptr;return ENOMEM;}self->offset=end;*out=reinterpret_cast<void*>(begin);return 0;}
 static void release(void*){}
 void*workspace=nullptr,*arena=nullptr;size_t arenaCapacity=0,offset=0;
};
}

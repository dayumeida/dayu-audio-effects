#pragma once
#include "RecoveredDualPrediction.hpp"
#include <array>

namespace dayu::recovered {
// Direct reconstruction of the per-channel work in ERA5 ARM64 0x2bf60.
// Region status is part of the rolling window state and is intentionally mutated.
class RepairLoop {
public:
    struct Region { int status, start, end; };
    void prepare(std::size_t maxFrame, std::size_t maxOrder=150) {
        for(auto& d:dual_)d.prepare(maxFrame,maxOrder);
        spline_.prepare(maxFrame); local_.assign(maxFrame,0.0);
        knotsX_.assign(maxFrame,0.0);knotsY_.assign(maxFrame,0.0);
        original_.assign(maxFrame,0.0);
    }
    void reset() noexcept {for(auto&d:dual_)d.reset();}
    void loadPolynomial(std::size_t ch,const double* p,std::size_t n)noexcept{if(ch<dual_.size())dual_[ch].loadPolynomial(p,n);}
    const double* polynomial(std::size_t ch)const noexcept{return dual_[ch].polynomial();}
    void process(double* data,std::size_t n,Region* regions,std::size_t count,
                 std::size_t ch,int lpContext,int splineContext,int processLimit,
                 int order,int quality)noexcept {
        if(!data||!regions||!count||ch>=dual_.size()||n>local_.size()||regions[0].start>processLimit)return;
        auto& dual=dual_[ch];bool estimateAfterDirect=false;
        for(std::size_t r=0;r<count && regions[r].start<=processLimit;++r){
            auto& current=regions[r];
            const int length=current.end-current.start+1;
            if(length<=0||current.start<0||std::size_t(current.end)>=n)continue;
            std::copy_n(data+current.start,length,original_.data());
            const bool isolated=count==1 || (r+1<count && regions[r+1].start-current.end>=lpContext);
            if(isolated&&current.status!=4){
                estimateAfterDirect=true;
                if(dual.repair(data,n,current.start,current.end,lpContext,order,true,true)==0)current.status=4;
                continue;
            }
            for(std::size_t j=r;j<count;++j){
                auto& region=regions[j];
                if(region.start-current.end>lpContext*2||region.status!=1)continue;
                const int size=region.end-region.start+1;
                if(size<=2){
                    double sum=0.0;int neighbors=0;
                    if(region.start>=1){sum=data[region.start-1]+0.0;neighbors=1;}
                    if(std::size_t(region.end+1)<n){sum=sum+data[region.end+1];++neighbors;}
                    const double value=sum/double(neighbors);
                    if(size>0)std::fill_n(data+region.start,size,value);
                    region.status=4;
                    estimateAfterDirect=estimateAfterDirect||(j==0)||(j==r);
                    continue;
                }
                splineFill(data,n,region,splineContext);
                region.status=2;
            }
            for(std::size_t j=r;j<count;++j){
                auto& region=regions[j];
                if(region.start-current.end>lpContext||region.status!=2)continue;
                const bool primary=quality==1 || (quality==0 && (j==0||estimateAfterDirect));
                const bool secondary=quality==1;
                const int result=dual.repair(data,n,region.start,region.end,lpContext,order,primary,secondary);
                estimateAfterDirect=estimateAfterDirect&&(quality!=0);
                if(result==0)region.status=3;
            }
            if(current.status==3){
                if(dual.repair(data,n,current.start,current.end,lpContext,order,true,true)==0)current.status=4;
                double magnitude=std::abs(data[current.start]);
                for(int i=1;i<length;++i)magnitude=magnitude+std::abs(data[current.start+i]);
                if(magnitude>originalMagnitude(original_.data(),length)*30.0)
                    std::copy_n(original_.data(),length,data+current.start);
            }
        }
    }
private:
    void splineFill(double* data,std::size_t n,const Region& r,int context)noexcept{
        const int length=r.end-r.start+1,left=std::min(r.start,context),right=std::min(int(n)-r.end-1,context);
        const int total=left+length+right;
        if(left<0||length<1||total<=0||std::size_t(total)>local_.size())return;
        std::copy_n(data+r.start-left,total,local_.data());
        if(left>=1&&right>=1){
            for(int i=0;i<left;++i){knotsX_[i]=double(i);knotsY_[i]=local_[i];}
            for(int i=0;i<right;++i){knotsX_[left+i]=double(left+length+i);knotsY_[left+i]=local_[left+length+i];}
            const std::size_t knotCount=left+right;
            if(spline_.build(knotsX_.data(),knotsY_.data(),knotCount))
                for(int i=left;i<left+length;++i)local_[i]=spline_.sample(knotsX_.data(),knotsY_.data(),knotCount,double(i));
        }
        std::copy_n(local_.data(),total,data+r.start-left);
    }
    static double originalMagnitude(const double*x,std::size_t n)noexcept{
        if(!n)return 0.0;if(n==1)return std::abs(x[0]);
        const std::size_t pairs=n&~std::size_t(1),quads=n&~std::size_t(3);
        double a=std::abs(x[0]),b=std::abs(x[1]);
        if(n>=4){double c=std::abs(x[2]),d=std::abs(x[3]);
            for(std::size_t i=4;i<quads;i+=4){a+=std::abs(x[i]);b+=std::abs(x[i+1]);c+=std::abs(x[i+2]);d+=std::abs(x[i+3]);}
            a=c+a;b=d+b;if(pairs>quads){a+=std::abs(x[quads]);b+=std::abs(x[quads+1]);}}
        double result=a+b;for(std::size_t i=pairs;i<n;++i)result+=std::abs(x[i]);return result;
    }
    std::array<DualPrediction,2>dual_;
    BesselSpline spline_;
    std::vector<double>local_,knotsX_,knotsY_,original_;
};
}

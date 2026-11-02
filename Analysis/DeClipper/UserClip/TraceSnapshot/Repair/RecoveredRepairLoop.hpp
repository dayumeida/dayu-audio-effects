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
        cancel();
        for(auto& d:dual_)d.prepare(maxFrame,maxOrder);
        spline_.prepare(maxFrame); local_.assign(maxFrame,0.0);
        knotsX_.assign(maxFrame,0.0);knotsY_.assign(maxFrame,0.0);
        original_.assign(maxFrame,0.0);
        statusScratch_.assign(maxFrame,0);
    }
    void reset() noexcept {cancel();for(auto&d:dual_)d.reset();}
    void loadPolynomial(std::size_t ch,const double* p,std::size_t n)noexcept{if(ch<dual_.size())dual_[ch].loadPolynomial(p,n);}
    const double* polynomial(std::size_t ch)const noexcept{return dual_[ch].polynomial();}
    void setReferenceHeapTail(bool enabled)noexcept{for(auto&d:dual_)d.setReferenceHeapTail(enabled);}
    void process(double* data,std::size_t n,Region* regions,std::size_t count,
                 std::size_t ch,int lpContext,int splineContext,int processLimit,
                 int order,int quality)noexcept {
        if(!begin(data,n,regions,count,ch,lpContext,splineContext,processLimit,order,quality))return;
        while(!step(std::uint32_t(-1))){}
    }
    bool begin(double* data,std::size_t n,Region* regions,std::size_t count,
               std::size_t ch,int lpContext,int splineContext,int processLimit,
               int order,int quality)noexcept {
        if(busy())return false;
        stage_=Stage::Done;
        workUnitsUpperBound_=0;
        estimatedCost_=0.0;
        if(!data||!regions||!count||ch>=dual_.size()||n>local_.size()||regions[0].start>processLimit)return true;
        data_=data;n_=n;regions_=regions;count_=count;channel_=ch;
        lpContext_=lpContext;splineContext_=splineContext;processLimit_=processLimit;order_=order;quality_=quality;
        workUnitsUpperBound_=estimateWorkUnits(n,regions,count,lpContext,processLimit,order,quality);
        regionIndex_=0;estimateAfterDirect_=false;stage_=Stage::Outer;return true;
    }
    bool step(std::uint32_t units=1)noexcept{
        while(units&&busy()){
            auto&dual=dual_[channel_];
            switch(stage_){
            case Stage::Outer:{
                if(regionIndex_>=count_||regions_[regionIndex_].start>processLimit_){stage_=Stage::Done;break;}
                auto&current=regions_[regionIndex_];length_=current.end-current.start+1;
                if(length_<=0||current.start<0||std::size_t(current.end)>=n_){++regionIndex_;break;}
                std::copy_n(data_+current.start,length_,original_.data());
                const bool isolated=count_==1||(regionIndex_+1<count_&&regions_[regionIndex_+1].start-current.end>=lpContext_);
                if(isolated&&current.status!=4){
                    estimateAfterDirect_=true;
                    dual.begin(data_,n_,current.start,current.end,lpContext_,order_,true,true);stage_=Stage::Direct;
                }else{scanIndex_=regionIndex_;stage_=Stage::Spline;}
                --units;break;}
            case Stage::Direct:
                if(dual.step(1)){if(dual.result()==0)regions_[regionIndex_].status=4;++regionIndex_;stage_=Stage::Outer;}
                --units;break;
            case Stage::Spline:{
                const int end=regions_[regionIndex_].end;
                while(scanIndex_<count_&&regions_[scanIndex_].start-end<=lpContext_*2&&regions_[scanIndex_].status!=1)++scanIndex_;
                if(scanIndex_==count_||regions_[scanIndex_].start-end>lpContext_*2){scanIndex_=regionIndex_;stage_=Stage::Preliminary;break;}
                auto&region=regions_[scanIndex_];const int size=region.end-region.start+1;
                if(size<=2){
                    double sum=0.0;int neighbors=0;
                    if(region.start>=1){sum=data_[region.start-1]+0.0;neighbors=1;}
                    if(std::size_t(region.end+1)<n_){sum=sum+data_[region.end+1];++neighbors;}
                    const double value=sum/double(neighbors);
                    if(size>0)std::fill_n(data_+region.start,size,value);
                    region.status=4;estimateAfterDirect_=estimateAfterDirect_||scanIndex_==0||scanIndex_==regionIndex_;
                }else{splineFill(data_,n_,region,splineContext_);region.status=2;}
                ++scanIndex_;--units;break;}
            case Stage::Preliminary:{
                const int end=regions_[regionIndex_].end;
                while(scanIndex_<count_&&regions_[scanIndex_].start-end<=lpContext_&&regions_[scanIndex_].status!=2)++scanIndex_;
                if(scanIndex_==count_||regions_[scanIndex_].start-end>lpContext_){stage_=Stage::Final;break;}
                auto&region=regions_[scanIndex_];
                const bool primary=quality_==1||(quality_==0&&(scanIndex_==0||estimateAfterDirect_));
                dual.begin(data_,n_,region.start,region.end,lpContext_,order_,primary,quality_==1);stage_=Stage::PreliminaryPredict;
                --units;break;}
            case Stage::PreliminaryPredict:
                if(dual.step(1)){
                    estimateAfterDirect_=estimateAfterDirect_&&(quality_!=0);
                    if(dual.result()==0)regions_[scanIndex_].status=3;
                    ++scanIndex_;stage_=Stage::Preliminary;
                }--units;break;
            case Stage::Final:{
                auto&current=regions_[regionIndex_];
                if(current.status==3){dual.begin(data_,n_,current.start,current.end,lpContext_,order_,true,true);stage_=Stage::FinalPredict;--units;}
                else{++regionIndex_;stage_=Stage::Outer;}
                break;}
            case Stage::FinalPredict:
                if(dual.step(1)){
                    auto&current=regions_[regionIndex_];if(dual.result()==0)current.status=4;
                    double magnitude=std::abs(data_[current.start]);
                    for(int i=1;i<length_;++i)magnitude=magnitude+std::abs(data_[current.start+i]);
                    if(magnitude>originalMagnitude(original_.data(),length_)*30.0){++trace::finalEnergyFallbacks;std::copy_n(original_.data(),length_,data_+current.start);}
                    ++regionIndex_;stage_=Stage::Outer;
                }--units;break;
            default:break;
            }
        }return !busy();
    }
    bool busy()const noexcept{return stage_!=Stage::Idle&&stage_!=Stage::Done;}
    double nextCost()const noexcept{
        if(!busy())return 0.0;
        if(stage_==Stage::Direct||stage_==Stage::PreliminaryPredict||stage_==Stage::FinalPredict)return dual_[channel_].nextCost();
        if(stage_==Stage::Spline){
            std::size_t j=scanIndex_;
            while(j<count_&&regions_[j].start-regions_[regionIndex_].end<=lpContext_*2&&regions_[j].status!=1)++j;
            if(j<count_&&regions_[j].start-regions_[regionIndex_].end<=lpContext_*2)return 2.0+double(regions_[j].end-regions_[j].start+1)*0.01;
        }return 0.5;
    }
    double estimatedCost()const noexcept{return estimatedCost_;}
    double estimatedCost(std::size_t n,const Region*regions,std::size_t count,int context,int limit,int order,int quality)noexcept{
        estimateWorkUnits(n,regions,count,context,limit,order,quality);return estimatedCost_;
    }
    std::uint64_t workUnitsUpperBound()const noexcept{return workUnitsUpperBound_;}
    // Geometry-only count. Exact when LPC polynomials remain finite; otherwise
    // a prediction may select its mean fallback and skip some IIR units.
    std::uint64_t estimateWorkUnits(std::size_t n,const Region*regions,std::size_t count,
             int context,int limit,int order,int quality)noexcept{
        estimatedCost_=0.0;
        if(!regions||!count||count>statusScratch_.size())return 0;
        for(std::size_t i=0;i<count;++i)statusScratch_[i]=regions[i].status;
        std::uint64_t units=1;double cost=0.5;bool afterDirect=false;
        const auto predictionUnits=[&](const Region&r,bool primary,bool secondary){
            const int length=r.end-r.start+1,left=std::min(r.start,context),right=std::min(int(n)-r.end-1,context);
            std::uint64_t cost=3;
            if(length<right&&order<right)cost+=(primary?order*2:0)+length+2;
            if(length<left&&order<left)cost+=(secondary?order*2:0)+length+2;
            return cost;
        };
        const auto succeeds=[&](const Region&r){const int length=r.end-r.start+1,left=std::min(r.start,context),right=std::min(int(n)-r.end-1,context);return (length<left&&order<left)||(length<right&&order<right);};
        for(std::size_t r=0;r<count&&regions[r].start<=limit;++r){
            if(regions[r].end<regions[r].start||regions[r].start<0||std::size_t(regions[r].end)>=n)continue;
            ++units;cost+=0.5;
            const bool isolated=count==1||(r+1<count&&regions[r+1].start-regions[r].end>=context);
            if(isolated&&statusScratch_[r]!=4){afterDirect=true;units+=predictionUnits(regions[r],true,true);cost+=DualPrediction::repairCost(n,regions[r].start,regions[r].end,context,order,true,true);if(succeeds(regions[r]))statusScratch_[r]=4;continue;}
            for(std::size_t j=r;j<count&&regions[j].start-regions[r].end<=context*2;++j){
                if(statusScratch_[j]!=1)continue;++units;cost+=2.0+double(regions[j].end-regions[j].start+1)*0.01;
                if(regions[j].end-regions[j].start+1<=2){statusScratch_[j]=4;afterDirect=afterDirect||j==0||j==r;}else statusScratch_[j]=2;
            }
            for(std::size_t j=r;j<count&&regions[j].start-regions[r].end<=context;++j){
                if(statusScratch_[j]!=2)continue;
                const bool primary=quality==1||(quality==0&&(j==0||afterDirect));
                units+=1+predictionUnits(regions[j],primary,quality==1);afterDirect=afterDirect&&quality!=0;
                cost+=0.5+DualPrediction::repairCost(n,regions[j].start,regions[j].end,context,order,primary,quality==1);
                if(succeeds(regions[j]))statusScratch_[j]=3;
            }
            if(statusScratch_[r]==3){units+=1+predictionUnits(regions[r],true,true);cost+=0.5+DualPrediction::repairCost(n,regions[r].start,regions[r].end,context,order,true,true);if(succeeds(regions[r]))statusScratch_[r]=4;}
        }estimatedCost_=cost;return units;
    }
    void cancel()noexcept{for(auto&d:dual_)d.cancel();stage_=Stage::Idle;}

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
    enum class Stage{Idle,Outer,Direct,Spline,Preliminary,PreliminaryPredict,Final,FinalPredict,Done};
    Stage stage_=Stage::Idle;
    double*data_=nullptr;Region*regions_=nullptr;
    std::size_t n_=0,count_=0,channel_=0,regionIndex_=0,scanIndex_=0;
    int lpContext_=0,splineContext_=0,processLimit_=0,order_=0,quality_=0,length_=0;
    bool estimateAfterDirect_=false;
    std::uint64_t workUnitsUpperBound_=0;
    double estimatedCost_=0.0;
    std::array<DualPrediction,2>dual_;
    BesselSpline spline_;
    std::vector<double>local_,knotsX_,knotsY_,original_;
    std::vector<int>statusScratch_;
};
}

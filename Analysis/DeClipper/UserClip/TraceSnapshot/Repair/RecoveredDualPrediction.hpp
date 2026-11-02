#pragma once
#include "RecoveredLPC.hpp"
namespace dayu::recovered {
// Recovered 0x2a4a8. Caller owns per-channel LPC cache and decides whether either
// direction recomputes it (quality/region scheduling is outside this class).
class DualPrediction {
public:
    void prepare(std::size_t maxFrame, std::size_t maxOrder) {
        cancel();
        local_.assign(maxFrame, 0.0); forward_.assign(maxFrame, 0.0);
        backward_.assign(maxFrame, 0.0); forwardWeights_.assign(maxFrame, 0.0);
        backwardWeights_.assign(maxFrame, 0.0); original_.assign(maxFrame, 0.0);
        backup_.assign(maxOrder+1,0.0); lpc_.prepare(maxFrame,maxOrder,maxFrame);
    }
    void reset() noexcept {cancel();lpc_.reset();}
    void loadPolynomial(const double* values,std::size_t n) noexcept {lpc_.loadPolynomial(values,n);}
    const double* polynomial() const noexcept {return lpc_.polynomial();}
    const double* forward() const noexcept{return forward_.data();}
    const double* backward() const noexcept{return backward_.data();}
    const double* forwardWeights() const noexcept{return forwardWeights_.data();}
    const double* backwardWeights() const noexcept{return backwardWeights_.data();}
    void setReferenceHeapTail(bool enabled)noexcept{lpc_.setReferenceHeapTail(enabled);}
    int repair(double* data, std::size_t n, std::size_t start, std::size_t end,
               std::size_t context, std::size_t order,
               bool estimatePrimary, bool estimateSecondary) noexcept {
        if(!begin(data,n,start,end,context,order,estimatePrimary,estimateSecondary))return 1;
        while(!step(std::size_t(-1))){}return result_;
    }
    bool begin(double*data,std::size_t n,std::size_t start,std::size_t end,
               std::size_t context,std::size_t order,bool primary,bool secondary)noexcept{
        if(busy())return false;
        result_=1;stage_=Stage::Done;
        if(!data||start>end||end>=n||n>local_.size())return true;
        data_=data;start_=start;left_=std::min(start,context);right_=std::min(n-end-1,context);
        length_=end-start+1;total_=left_+length_+right_;order_=order;
        primary_=primary;secondary_=secondary;predicted_=false;
        ramp_=(left_>=length_)&&(right_+1>=length_);
        std::copy_n(data+start-left_,total_,local_.data());
        std::fill_n(forward_.data(),length_,0.0);std::fill_n(backward_.data(),length_,0.0);
        std::fill_n(forwardWeights_.data(),length_,0.0);std::fill_n(backwardWeights_.data(),length_,0.0);
        stage_=Stage::BackwardStart;return true;
    }
    bool step(std::size_t budget=1)noexcept{
        while(budget&&busy()){
            switch(stage_){
            case Stage::BackwardStart:
                if(length_<right_){
                    std::reverse(local_.begin()+left_+length_,local_.begin()+total_);
                    if(lpc_.beginPredict(local_.data()+left_+length_,right_,length_,order_,primary_))stage_=Stage::BackwardPredict;
                    else {std::reverse(local_.begin()+left_+length_,local_.begin()+total_);stage_=Stage::ForwardStart;}
                }else stage_=Stage::ForwardStart;
                --budget;break;
            case Stage::BackwardPredict:
                if(lpc_.stepPredict(1)){
                    std::copy_n(lpc_.output(),length_,backward_.data());
                    for(std::size_t i=0;i<length_;++i)backwardWeights_[i]=ramp_?double(i+1):1.0;
                    std::reverse(local_.begin()+left_+length_,local_.begin()+total_);predicted_=true;stage_=Stage::ForwardStart;
                }--budget;break;
            case Stage::ForwardStart:
                if(secondary_)std::copy_n(lpc_.polynomial(),order_+1,backup_.data());
                if(length_<left_&&lpc_.beginPredict(local_.data(),left_,length_,order_,secondary_))stage_=Stage::ForwardPredict;
                else stage_=Stage::Blend;
                --budget;break;
            case Stage::ForwardPredict:
                if(lpc_.stepPredict(1)){
                    std::copy_n(lpc_.output(),length_,forward_.data());
                    for(std::size_t i=0;i<length_;++i)forwardWeights_[i]=ramp_?double(i+1):1.0;
                    predicted_=true;stage_=Stage::Blend;
                }--budget;break;
            case Stage::Blend:blend();stage_=Stage::Done;--budget;break;
            default:break;
            }
        }return !busy();
    }
    bool busy()const noexcept{return stage_!=Stage::Idle&&stage_!=Stage::Done;}
    double nextCost()const noexcept{
        if(stage_==Stage::BackwardPredict||stage_==Stage::ForwardPredict)return lpc_.nextCost();
        return busy()?0.5+double(total_)/4000.0:0.0;
    }
    static double repairCost(std::size_t n,std::size_t start,std::size_t end,
              std::size_t context,std::size_t order,bool primary,bool secondary)noexcept{
        if(start>end||end>=n)return 0.0;
        const auto left=std::min(start,context),right=std::min(n-end-1,context),length=end-start+1;
        double cost=3.0*(0.5+double(left+length+right)/4000.0);
        if(length<right&&order<right)cost+=LPC::predictionCost(right,length,order,primary);
        if(length<left&&order<left)cost+=LPC::predictionCost(left,length,order,secondary);
        return cost;
    }
    int result()const noexcept{return result_;}
    void cancel()noexcept{lpc_.cancelPredict();stage_=Stage::Idle;}
private:
    void blend()noexcept{++trace::dualCalls;
        if(secondary_)lpc_.loadPolynomial(backup_.data(),order_+1);
        if(!predicted_){++trace::geometryFailures;std::copy_n(local_.data(),total_,data_+start_-left_);result_=2;return;}
        std::copy_n(local_.data()+left_,length_,original_.data());
        for(std::size_t i=0;i<length_;++i){
            const double first=forward_[i]*forwardWeights_[length_-1-i];
            const double second=backward_[length_-1-i]*backwardWeights_[i];
            const double denominator=forwardWeights_[i]+backwardWeights_[length_-1-i];
            local_[left_+i]=(first+second)/denominator;
        }
        const double repairedMagnitude=absSum(local_.data()+left_,length_);
        const double originalMagnitude=absSum(original_.data(),length_);
        if(repairedMagnitude>originalMagnitude+originalMagnitude){++trace::dualEnergyFallbacks;
            std::copy_n(original_.data(),length_,local_.data()+left_);}
        std::copy_n(local_.data(),total_,data_+start_-left_);result_=0;
    }
private:
    // Same four-value pairwise sum as 2b9e4..2bb5c (absolute values).
    static double absSum(const double*x,std::size_t n) noexcept {
        if(!n)return 0.0;
        if(n<2)return std::abs(x[0]);
        const std::size_t pairs=n&~std::size_t(1),quads=n&~std::size_t(3);
        double a=std::abs(x[0]),b=std::abs(x[1]);
        if(n>=4){double c=std::abs(x[2]),d=std::abs(x[3]);
            for(std::size_t i=4;i<quads;i+=4){a+=std::abs(x[i]);b+=std::abs(x[i+1]);c+=std::abs(x[i+2]);d+=std::abs(x[i+3]);}
            a=c+a;b=d+b;if(pairs>quads){a+=std::abs(x[quads]);b+=std::abs(x[quads+1]);}}
        double result=a+b;for(std::size_t i=pairs;i<n;++i)result+=std::abs(x[i]);return result;
    }
    LPC lpc_;
    enum class Stage{Idle,BackwardStart,BackwardPredict,ForwardStart,ForwardPredict,Blend,Done};
    Stage stage_=Stage::Idle;int result_=0;
    double*data_=nullptr;
    std::size_t start_=0,left_=0,right_=0,length_=0,total_=0,order_=0;
    bool primary_=false,secondary_=false,predicted_=false,ramp_=false;
    std::vector<double> local_,forward_,backward_,forwardWeights_,backwardWeights_,original_,backup_;
};
class BesselSpline {
public:
    void prepare(std::size_t maxKnots){slopes_.assign(maxKnots,0.0);secants_.assign(maxKnots,0.0);}
    bool build(const double* x,const double* y,std::size_t n)noexcept {
        if(n<2||n>slopes_.size())return false;
        for(std::size_t i=0;i+1<n;++i){if(!(x[i+1]>x[i]))return false;secants_[i]=(y[i+1]-y[i])/(x[i+1]-x[i]);}
        if(n==2){slopes_[0]=slopes_[1]=secants_[0];return true;}
        slopes_[0]=secants_[0]*1.5-secants_[1]*0.5;
        slopes_[n-1]=secants_[n-2]*1.5-secants_[n-3]*0.5;
        for(std::size_t i=1;i+1<n;++i){const double hp=x[i]-x[i-1],hn=x[i+1]-x[i];
            slopes_[i]=(secants_[i-1]*hn+hp*secants_[i])/(hp+hn);}
        return true;
    }
    double sample(const double* x,const double* y,std::size_t n,double position)const noexcept {
        auto upper=std::upper_bound(x,x+n,position);std::size_t i=upper==x?0:std::size_t(upper-x-1);i=std::min(i,n-2);
        const double distance=position-x[i],h=x[i+1]-x[i],t=distance/h;
        const double t2=t*t;const double blend=t2*(3.0-(t+t));
        const double h00=1.0-blend,h01=blend;
        const double h10=(t*(t-2.0)+1.0)*distance;
        const double h11=(t*distance)*(t-1.0);
        return ((h00*y[i]+h01*y[i+1])+h10*slopes_[i])+h11*slopes_[i+1];
    }
    const double* slopes()const noexcept{return slopes_.data();}
private:std::vector<double>slopes_,secants_;
};
}

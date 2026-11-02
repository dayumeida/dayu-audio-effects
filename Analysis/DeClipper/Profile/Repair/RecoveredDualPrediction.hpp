#pragma once
#include "RecoveredLPC.hpp"
namespace dayu::recovered {
// Recovered 0x2a4a8. Caller owns per-channel LPC cache and decides whether either
// direction recomputes it (quality/region scheduling is outside this class).
class DualPrediction {
public:
    void prepare(std::size_t maxFrame, std::size_t maxOrder) {
        local_.assign(maxFrame, 0.0); forward_.assign(maxFrame, 0.0);
        backward_.assign(maxFrame, 0.0); forwardWeights_.assign(maxFrame, 0.0);
        backwardWeights_.assign(maxFrame, 0.0); original_.assign(maxFrame, 0.0);
        backup_.assign(maxOrder+1,0.0); lpc_.prepare(maxFrame,maxOrder,maxFrame);
    }
    void reset() noexcept { lpc_.reset(); }
    void loadPolynomial(const double* values,std::size_t n) noexcept {lpc_.loadPolynomial(values,n);}
    const double* polynomial() const noexcept {return lpc_.polynomial();}
    const double* forward() const noexcept{return forward_.data();}
    const double* backward() const noexcept{return backward_.data();}
    const double* forwardWeights() const noexcept{return forwardWeights_.data();}
    const double* backwardWeights() const noexcept{return backwardWeights_.data();}
    int repair(double* data, std::size_t n, std::size_t start, std::size_t end,
               std::size_t context, std::size_t order,
               bool estimatePrimary, bool estimateSecondary) noexcept {
        if(!data||start>end||end>=n||n>local_.size())return 1;
        const std::size_t left=std::min(start,context),right=std::min(n-end-1,context);
        const std::size_t length=end-start+1,total=left+length+right;
        std::copy_n(data+start-left,total,local_.data());
        if(total<length)return 2;
        std::fill_n(forward_.data(),length,0.0);std::fill_n(backward_.data(),length,0.0);
        std::fill_n(forwardWeights_.data(),length,0.0);std::fill_n(backwardWeights_.data(),length,0.0);
        bool predicted=false;
        const bool ramp=(left>=length)&&(right+1>=length);
        if(length<right){
            std::reverse(local_.begin()+left+length,local_.begin()+total);
            lpc_.predict(local_.data()+left+length,right,length,order,estimatePrimary);
            std::copy_n(lpc_.output(),length,backward_.data());
            for(std::size_t i=0;i<length;++i)backwardWeights_[i]=ramp?double(i+1):1.0;
            std::reverse(local_.begin()+left+length,local_.begin()+total);
            predicted=true;
        }
        if(estimateSecondary)std::copy_n(lpc_.polynomial(),order+1,backup_.data());
        if(length<left){
            lpc_.predict(local_.data(),left,length,order,estimateSecondary);
            std::copy_n(lpc_.output(),length,forward_.data());
            for(std::size_t i=0;i<length;++i)forwardWeights_[i]=ramp?double(i+1):1.0;
            predicted=true;
        }
        if(estimateSecondary)lpc_.loadPolynomial(backup_.data(),order+1);
        if(!predicted){std::copy_n(local_.data(),total,data+start-left);return 2;}
        std::copy_n(local_.data()+left,length,original_.data());
        for(std::size_t i=0;i<length;++i){
            const double first=forward_[i]*forwardWeights_[length-1-i];
            const double second=backward_[length-1-i]*backwardWeights_[i];
            const double denominator=forwardWeights_[i]+backwardWeights_[length-1-i];
            local_[left+i]=(first+second)/denominator;
        }
        const double repairedMagnitude=absSum(local_.data()+left,length);
        const double originalMagnitude=absSum(original_.data(),length);
        if(repairedMagnitude>originalMagnitude+originalMagnitude)
            std::copy_n(original_.data(),length,local_.data()+left);
        std::copy_n(local_.data(),total,data+start-left);
        return 0;
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

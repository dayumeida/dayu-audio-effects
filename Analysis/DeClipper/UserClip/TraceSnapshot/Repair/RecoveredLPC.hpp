#pragma once
#include "../TraceCounters.hpp"
// ERA5 5.4.00 ARM64 reconstruction of 0x43348 and its Burg/FIR/IIR operations.
// This is a recovered subroutine, not a complete De-Clipper implementation.
// Native AU observations in lpc-runtime-calls.json are the comparison oracle.
// Compile with -ffp-contract=off; never enable fast-math.
#include <Accelerate/Accelerate.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace dayu::recovered {
class LPC {
public:
    void prepare(std::size_t maxContext, std::size_t maxOrder, std::size_t maxPrediction) {
        cancelPredict();
        contextCapacity_ = maxContext; orderCapacity_ = maxOrder;
        forward_.assign(maxContext, 0.0); backward_.assign(maxContext, 0.0);
        product_.assign(maxContext, 0.0); polynomial_.assign(maxOrder + 1, 0.0);
        reversePolynomial_.assign(maxOrder + 1, 0.0); reflection_.assign(maxOrder, 0.0);
        negPolynomial_.assign(maxOrder, 0.0); reverseContext_.assign(maxOrder, 0.0);
        paddedContext_.assign(maxOrder * 3, 0.0); convolution_.assign(maxOrder * 2, 0.0);
        residual_.assign(std::max(maxOrder, maxPrediction), 0.0);
        state_.assign(maxOrder, 0.0); output_.assign(maxPrediction, 0.0);
    }
    void reset() noexcept {
        cancelPredict();
        std::fill(polynomial_.begin(), polynomial_.end(), 0.0);
        std::fill(reflection_.begin(), reflection_.end(), 0.0);
    }
    // The source subtracts then adds the mean in place. Preserve the rounding on
    // the context because a later backward prediction can consume this same view.
    bool predict(double* context, std::size_t n, std::size_t count,
                 std::size_t order, bool estimate) noexcept {
        if(!beginPredict(context,n,count,order,estimate))return false;
        while(!stepPredict(std::size_t(-1))){}
        return predictionValid_;
    }
    // A context view must remain alive and exclusive until stepPredict returns
    // true or cancelPredict restores its mean. One budget unit is one Burg
    // order, one polynomial order, one FIR priming pass, or one IIR sample.
    bool beginPredict(double* context,std::size_t n,std::size_t count,
                      std::size_t order,bool estimate)noexcept{
        if(predicting())return false;
        if (!context || n < 2 || order >= n || order > orderCapacity_ ||
            n > contextCapacity_ || count > output_.size()) return false;
        taskContext_=context;taskN_=n;taskCount_=count;taskOrder_=order;taskIndex_=0;
        taskMean_=armMean(context,n);predictionValid_=true;
        for(std::size_t i=0;i<n;++i)context[i]=context[i]-taskMean_;
        std::fill_n(output_.data(), count, 0.0);
        if(estimate){initializeBurg(context,n);std::fill_n(reversePolynomial_.data(),order+1,0.0);stage_=Stage::Burg;}
        else stage_=Stage::Prime;
        return true;
    }
    bool stepPredict(std::size_t budget)noexcept{
        while(budget&&predicting()){
            switch(stage_){
            case Stage::Burg:
                if(taskIndex_<taskOrder_){burgOrder(taskN_,taskIndex_++);--budget;}
                if(taskIndex_==taskOrder_){polynomial_[0]=1.0;taskIndex_=0;stage_=Stage::Polynomial;}
                break;
            case Stage::Polynomial:
                if(taskIndex_<taskOrder_){polynomialOrder(taskOrder_,taskIndex_++);--budget;}
                if(taskIndex_==taskOrder_)stage_=Stage::Prime;
                break;
            case Stage::Prime:
                ++trace::predictions;for(double a:polynomial_)predictionValid_=predictionValid_&&std::isfinite(a);
                if(!predictionValid_)++trace::invalidPolynomial;
                if(predictionValid_&&taskOrder_){prime(taskContext_,taskN_,taskCount_,taskOrder_);stage_=Stage::Filter;taskIndex_=0;}
                else stage_=Stage::Finish;
                --budget;break;
            case Stage::Filter:
                if(taskIndex_<taskCount_){filterSample(taskIndex_++,taskOrder_);--budget;}
                if(taskIndex_==taskCount_)stage_=Stage::Finish;
                break;
            case Stage::Finish:
                for(std::size_t i=0;i<taskCount_;++i)output_[i]=taskMean_+output_[i];
                restoreContext();stage_=Stage::Done;--budget;break;
            default:break;
            }
        }
        return !predicting();
    }
    bool predicting()const noexcept{return stage_!=Stage::Idle&&stage_!=Stage::Done;}
    double nextCost()const noexcept{
        switch(stage_){
        case Stage::Burg:if(taskIndex_<taskOrder_)return (2.0*double(taskN_)-double(taskIndex_)-2.0)/1524.0;[[fallthrough]];
        case Stage::Polynomial:if(taskIndex_<taskOrder_)return double(taskIndex_+1)/500.0;[[fallthrough]];
        case Stage::Prime:return 2.0+double(taskOrder_)*double(taskOrder_)/3500.0;
        case Stage::Filter:return double(taskOrder_)/250.0;
        case Stage::Finish:return 0.4+double(taskN_+taskCount_)/5000.0;
        default:return 0.0;
        }
    }
    static double predictionCost(std::size_t n,std::size_t count,std::size_t order,bool estimate)noexcept{
        if(n<2||order>=n)return 0.0;
        const double p=double(order),length=double(n);
        double cost=2.0+p*p/3500.0+double(count)*p/250.0+0.4+double(n+count)/5000.0;
        if(estimate)cost+=(p*(2.0*length-2.0)-p*(p-1.0)*0.5)/1524.0+p*(p+1.0)/1000.0;
        return cost;
    }
    bool predictionValid()const noexcept{return predictionValid_;}
    void cancelPredict()noexcept{if(predicting())restoreContext();stage_=Stage::Idle;}
private:
    void restoreContext()noexcept{
        if(taskContext_)for(std::size_t i=0;i<taskN_;++i)taskContext_[i]=taskMean_+taskContext_[i];
        taskContext_=nullptr;
    }
    void prime(const double*context,std::size_t n,std::size_t count,std::size_t order)noexcept{
            for (std::size_t i = 0; i < order; ++i) {
                negPolynomial_[i] = -polynomial_[order - i];
                reverseContext_[i] = context[n - 1 - i];
            }
            std::fill_n(paddedContext_.data(), order * 3, 0.0);
            std::copy_n(reverseContext_.data(), order, paddedContext_.data() + order - 1);
            vDSP_convD(paddedContext_.data(), 1, negPolynomial_.data() + order - 1,
                       -1, convolution_.data(), 1, order * 2 - 1, order);
            std::fill_n(residual_.data(), std::max(order, count), 0.0);
            for (std::size_t i = 0; i < order; ++i) residual_[i] = convolution_[order - 1 - i];
            // The ARM64 reference reads beyond its 150-double residual buffer
            // for long regions. Normal AU observations show malloc's 160-double
            // slot spacing exposes these two following arrays. Reproduce that
            // bounded observed layout without any out-of-bounds access here.
            // This is allocator-specific reference behavior, not LPC theory.
            if(referenceHeapTail_ && orderCapacity_==150){
                for(std::size_t i=160;i<count&&i<310;++i)residual_[i]=negPolynomial_[i-160];
                for(std::size_t i=320;i<count&&i<470;++i)residual_[i]=reverseContext_[i-320];
            }
            std::fill_n(state_.data(), order, 0.0);
            taskInvA0_=1.0/polynomial_[0];
            stateFinite_=true;
    }
    void filterSample(std::size_t i,std::size_t order)noexcept{
                double w = residual_[i];
                // The reference numerator is [1, 0, ... 0]. For finite state
                // and its normalized a0=1, these omitted zero products are
                // exactly +0 under the source's operation order. Preserve the
                // full path once an infinity/NaN enters the state.
                if(taskInvA0_==1.0&&stateFinite_){
                    for(std::size_t j=0;j<order;++j){
                        const double product=polynomial_[j+1]*state_[order-1-j];
                        w=w-product;
                    }
                    output_[i]=0.0+w;
                    stateFinite_=std::isfinite(w);
                    for(std::size_t j=1;j<order;++j)state_[j-1]=state_[j];
                    state_[order-1]=w;
                    return;
                }
                for (std::size_t j = 0; j < order; ++j) {
                    const double coefficient = polynomial_[j + 1] * taskInvA0_;
                    const double product = coefficient * state_[order - 1 - j];
                    w = w - product;
                }
                double numerator = 0.0;
                for (std::size_t j = 0; j < order; ++j) {
                    const double product = 0.0 * state_[order - 1 - j];
                    numerator = numerator + product;
                }
                const double firstTerm = 1.0 * w;
                const double y = (numerator + firstTerm) / polynomial_[0];
                output_[i] = y;
                for (std::size_t j = 1; j < order; ++j) state_[j - 1] = state_[j];
                state_[order - 1] = w;
    }
public:
    void loadPolynomial(const double* values, std::size_t count) noexcept {
        std::copy_n(values, std::min(count, polynomial_.size()), polynomial_.data());
    }
    void setReferenceHeapTail(bool enabled)noexcept{referenceHeapTail_=enabled;}
    const double* output() const noexcept { return output_.data(); }
    const double* polynomial() const noexcept { return polynomial_.data(); }
    const double* reflection() const noexcept { return reflection_.data(); }
    const double* residual() const noexcept { return residual_.data(); }
    // Three aligned unit-stride dot products with the observed ARM64 vDSP
    // reduction tree, fused into one memory traversal. Explicit NEON FMA is
    // required here: ordinary contraction is disabled for the recovered DSP.
    static void combinedDot(const double*f,const double*b,std::size_t n,
                            double&ff,double&fb,double&bb)noexcept{
#if defined(__aarch64__)
        float64x2_t a[8],c[8],d[8];
        for(unsigned j=0;j<8;++j)a[j]=c[j]=d[j]=vdupq_n_f64(0.0);
        std::size_t i=0;
        for(;i+16<=n;i+=16){
            for(unsigned j=0;j<8;++j){
                const auto x=vld1q_f64(f+i+j*2),y=vld1q_f64(b+i+j*2);
                a[j]=vfmaq_f64(a[j],x,x);c[j]=vfmaq_f64(c[j],x,y);d[j]=vfmaq_f64(d[j],y,y);
            }
        }
        if(i){for(unsigned j=0;j<4;++j){a[j]=vaddq_f64(a[j*2+1],a[j*2]);c[j]=vaddq_f64(c[j*2+1],c[j*2]);d[j]=vaddq_f64(d[j*2+1],d[j*2]);}}
        if(i+8<=n){for(unsigned j=0;j<4;++j){
            const auto x=vld1q_f64(f+i+j*2),y=vld1q_f64(b+i+j*2);
            a[j]=vfmaq_f64(a[j],x,x);c[j]=vfmaq_f64(c[j],x,y);d[j]=vfmaq_f64(d[j],y,y);
        }i+=8;}
        for(unsigned j=0;j<2;++j){a[j]=vaddq_f64(a[j*2+1],a[j*2]);c[j]=vaddq_f64(c[j*2+1],c[j*2]);d[j]=vaddq_f64(d[j*2+1],d[j*2]);}
        for(;i+2<=n;i+=2){const auto x=vld1q_f64(f+i),y=vld1q_f64(b+i);a[0]=vfmaq_f64(a[0],x,x);c[0]=vfmaq_f64(c[0],x,y);d[0]=vfmaq_f64(d[0],y,y);}
        ff=vaddvq_f64(vaddq_f64(a[1],a[0]))+0.0;
        fb=vaddvq_f64(vaddq_f64(c[1],c[0]))+0.0;
        bb=vaddvq_f64(vaddq_f64(d[1],d[0]))+0.0;
        if(i<n){ff=std::fma(f[i],f[i],ff);fb=std::fma(f[i],b[i],fb);bb=std::fma(b[i],b[i],bb);}
#else
        vDSP_dotprD(f,1,f,1,&ff,n);vDSP_dotprD(f,1,b,1,&fb,n);vDSP_dotprD(b,1,b,1,&bb,n);
#endif
    }
    // ARM64 compiler's pairwise four-lane reduction, with an 8-byte prefix when
    // the native double pointer is not 16-byte aligned (43398..434c0).
    static double armMean(const double* x, std::size_t n) noexcept {
        if (!n) return 0.0;
        const std::size_t prefix = std::min<std::size_t>((reinterpret_cast<std::uintptr_t>(x) >> 3) & 1, n);
        const std::size_t rest = n - prefix;
        double sum = 0.0;
        if (rest + 1 >= 3) {
            const std::size_t pairs = rest & ~std::size_t(1);
            double a0 = x[prefix], a1 = x[prefix + 1];
            if (rest >= 4) {
                const std::size_t quads = rest & ~std::size_t(3);
                double b0 = x[prefix + 2], b1 = x[prefix + 3];
                for (std::size_t i = 4; i < quads; i += 4) {
                    a0 = a0 + x[prefix + i]; a1 = a1 + x[prefix + i + 1];
                    b0 = b0 + x[prefix + i + 2]; b1 = b1 + x[prefix + i + 3];
                }
                a0 = b0 + a0; a1 = b1 + a1;
                if (pairs > quads) { a0 = a0 + x[prefix + quads]; a1 = a1 + x[prefix + quads + 1]; }
            }
            sum = a0 + a1;
            if (prefix) sum = sum + x[0];
            for (std::size_t i = prefix + pairs; i < n; ++i) sum = sum + x[i];
        } else {
            sum = x[0];
            for (std::size_t i = 1; i < n; ++i) sum = sum + x[i];
        }
        return sum / double(n);
    }
private:
    void initializeBurg(const double* x, std::size_t n) noexcept {
        std::fill(polynomial_.begin(), polynomial_.end(), 0.0);
        std::fill(reflection_.begin(), reflection_.end(), 0.0);
        std::fill_n(forward_.data(), n, 0.0);
        std::fill_n(backward_.data(), n, 0.0);
        std::fill_n(product_.data(), n, 0.0);
        std::copy_n(x + 1, n - 1, forward_.data());
        std::copy_n(x, n - 1, backward_.data());
    }
    void burgOrder(std::size_t n,std::size_t m)noexcept{
            double* const fwd=forward_.data();double* const back=backward_.data();
            double ef, eb, cross;
            combinedDot(fwd,back,n-1,ef,cross,eb);
            ef = std::sqrt(ef); ef = ef * ef;
            eb = std::sqrt(eb); eb = eb * eb;
            const double k = (cross * -2.0) / (eb + ef);
            reflection_[m] = k;
            // vDSP_vsdivD uses multiplication by the rounded reciprocal. Keep
            // that operation and the following add/multiply distinct, including
            // k==0's NaN behavior; this is not an algebraic Burg simplification.
            const double reciprocal=1.0/k;
            const std::size_t active=n-m-2;
            std::size_t i=0;
#if defined(__aarch64__)
            if(active>=8){
                const auto vk=vdupq_n_f64(k),vi=vdupq_n_f64(reciprocal);
                float64x2_t f[5],b[5];f[0]=vld1q_f64(fwd);b[0]=vld1q_f64(back);
                for(;i+8<=active;i+=8){
                    for(unsigned j=1;j<=4;++j){f[j]=vld1q_f64(fwd+i+j*2);b[j]=vld1q_f64(back+i+j*2);}
                    for(unsigned j=0;j<4;++j){
                        const auto shiftedF=vextq_f64(f[j],f[j+1],1),shiftedB=vextq_f64(b[j],b[j+1],1);
                        auto newB=vmulq_f64(b[j],vi);newB=vaddq_f64(f[j],newB);newB=vmulq_f64(newB,vk);
                        const auto product=vmulq_f64(shiftedB,vk),newF=vaddq_f64(shiftedF,product);
                        vst1q_f64(back+i+j*2,newB);vst1q_f64(fwd+i+j*2,newF);
                    }f[0]=f[4];b[0]=b[4];
                }
            }
            if(i+2<=active){
                const auto vk=vdupq_n_f64(k),vi=vdupq_n_f64(reciprocal);
                auto f=vld1q_f64(fwd+i),b=vld1q_f64(back+i);
                for(;i+2<=active;i+=2){
                    const auto nextF=vld1q_f64(fwd+i+2),nextB=vld1q_f64(back+i+2);
                    const auto shiftedF=vextq_f64(f,nextF,1),shiftedB=vextq_f64(b,nextB,1);
                    auto newB=vmulq_f64(b,vi);newB=vaddq_f64(f,newB);newB=vmulq_f64(newB,vk);
                    const auto product=vmulq_f64(shiftedB,vk),newF=vaddq_f64(shiftedF,product);
                    vst1q_f64(back+i,newB);vst1q_f64(fwd+i,newF);
                    f=nextF;b=nextB;
                }
            }
#endif
            for(;i<active;++i){
                const double product=back[i+1]*k;
                double newB=back[i]*reciprocal;newB=fwd[i]+newB;newB=newB*k;
                const double newF=fwd[i+1]+product;
                back[i]=newB;fwd[i]=newF;
            }
            // Previous orders already cleared the rest of this tail.
            back[active]=0.0;fwd[active]=0.0;
    }
    void polynomialOrder(std::size_t order,std::size_t m)noexcept{
            // Higher coefficients are still zero at this order. Their reversed
            // slots were cleared once at beginPredict and need no repeated copy.
            for (std::size_t i = 0; i <= m; ++i) reversePolynomial_[order-i]=polynomial_[i];
            for (std::size_t i = 0; i <= m; ++i) {
                const double product = reflection_[m] * reversePolynomial_[order - m + i];
                polynomial_[i + 1] = polynomial_[i + 1] + product;
            }
    }
    std::size_t contextCapacity_ = 0, orderCapacity_ = 0;
    enum class Stage{Idle,Burg,Polynomial,Prime,Filter,Finish,Done};
    Stage stage_=Stage::Idle;
    double*taskContext_=nullptr;
    std::size_t taskN_=0,taskCount_=0,taskOrder_=0,taskIndex_=0;
    double taskMean_=0.0,taskInvA0_=0.0;
    bool predictionValid_=true;
    bool stateFinite_=true;
    bool referenceHeapTail_=false;
    std::vector<double> forward_, backward_, product_, polynomial_, reversePolynomial_, reflection_;
    std::vector<double> negPolynomial_, reverseContext_, paddedContext_, convolution_, residual_, state_, output_;
};
}

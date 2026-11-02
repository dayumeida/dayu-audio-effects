#include "../大鱼音频效果器Extension/DSP/ReferenceLimiter.hpp"
#include <cassert>
#include <cstdlib>
#include <iostream>
#include <limits>
#include <random>

static bool watchAllocations = false;
static std::size_t allocations = 0;
void *operator new(std::size_t n) {
    if (watchAllocations) ++allocations;
    if (auto p = std::malloc(n)) return p;
    throw std::bad_alloc();
}
void operator delete(void *p) noexcept { std::free(p); }
void operator delete(void *p, std::size_t) noexcept { std::free(p); }

// Deliberately simple transcription of the active original loop. It uses a
// full peak-ring scan when the cached-peak countdown expires, and exp per sample.
// It serves as a mathematical-equivalence oracle, not a runtime-original oracle.
struct NaiveLimiter {
    unsigned channels, chunk, n, half, padding, offset, pos=0, smoothPos=0;
    int countdown=0;
    float peak=0,sum1=0,sum2=0,reduction=0;
    std::array<std::vector<float>,2> audio,delay;
    std::vector<float> peaks,peakRing,s1,s2;
    float fs;
    NaiveLimiter(unsigned rate, unsigned ch):channels(ch),chunk(2048),fs(float(rate)) {
        const auto w50=unsigned(double(rate)*.05);
        n=unsigned(fs*.2f);half=n/2;
        padding=unsigned(fs*.2f+float(8*w50));offset=(padding-4*w50)/2;
        for(auto &v:audio)v.assign(chunk+padding,0.f);
        for(auto &v:delay)v.assign(n,0.f);
        peaks.assign(chunk+padding,0.f);peakRing.assign(n,0.f);
        s1.assign(half,0.f);s2.assign(half,0.f);
    }
    void process(float *const *in,float *const *out,float target) {
        for(unsigned c=0;c<channels;++c)std::copy_n(in[c],chunk,audio[c].data());
        std::fill(peaks.begin(),peaks.end(),0.f);
        for(unsigned c=0;c<channels;++c)for(unsigned i=0;i<peaks.size();++i)
            peaks[i]=std::max(peaks[i],std::abs(audio[c][i]));
        const float makeup=float(std::pow(10.,(double(target)+1.6)/20.));
        for(unsigned i=0;i<peaks.size();++i) {
            peakRing[pos]=peaks[i];
            if(--countdown<0) {peak=*std::max_element(peakRing.begin(),peakRing.end());countdown=int(n);}
            else if(std::abs(peaks[i])>peak){peak=std::abs(peaks[i]);countdown=int(n);}
            float driven=peak*1.2f;
            float raw=driven>1.f?1.f-1.f/driven:0.f;
            raw/=float(half);
            sum1=(sum1+raw)-s1[smoothPos];s1[smoothPos]=raw;
            float second=sum1/float(half);
            sum2=(sum2+second)-s2[smoothPos];s2[smoothPos]=second;
            float alpha=float(std::exp(-1./double((fs*.2f)*.5f)));
            reduction=std::max(sum2,std::max(reduction*alpha,0.f));
            for(unsigned c=0;c<channels;++c){
                float old=delay[c][pos];delay[c][pos]=audio[c][i];
                audio[c][i]=(old*(1.f-reduction))*makeup;
            }
            if(++pos==n)pos=0;
            if(++smoothPos==half)smoothPos=0;
        }
        for(unsigned c=0;c<channels;++c)std::copy_n(audio[c].data()+offset,chunk,out[c]);
    }
};

int main() {
    float largestDifference=0.f;
    std::mt19937 random(20261101);
    std::uniform_real_distribution<float> noise(-1.f,1.f);
    for(unsigned rate:{44100u,48000u,96000u})for(unsigned channels:{1u,2u}) {
        dayu::ReferenceLimiter candidate;candidate.prepare(rate,2,512);
        NaiveLimiter oracle(rate,channels);
        std::array<std::vector<float>,2> in,out,expected;
        std::array<float*,2> pi{},po{},pe{};
        for(unsigned c=0;c<2;++c){in[c].resize(2048);out[c].resize(2048);expected[c].resize(2048);pi[c]=in[c].data();po[c]=out[c].data();pe[c]=expected[c].data();}
        for(unsigned block=0;block<14;++block) {
            for(unsigned c=0;c<channels;++c)for(unsigned i=0;i<2048;++i)
                in[c][i]=block<4?noise(random)*2.3f:(block<8?noise(random)*.15f:0.f);
            if(block==1)in[0][101]=9.f;
            watchAllocations=true;
            candidate.processReadyChunk(pi.data(),po.data(),channels,-12.f);
            watchAllocations=false;
            oracle.process(pi.data(),pe.data(),-12.f);
            for(unsigned c=0;c<channels;++c)for(unsigned i=0;i<2048;++i) {
                assert(std::isfinite(out[c][i]));
                largestDifference=std::max(largestDifference,std::abs(out[c][i]-expected[c][i]));
            }
        }
    }
    assert(largestDifference<1e-6f);
    // Compare streamed arbitrary segmentation with the chunk scheduler, including
    // initial accumulation latency, in-place processing, and a short final block.
    const unsigned total=2048*9+333,latency=2047;
    std::array<std::vector<float>,2> input,expected,actual;
    for(unsigned c=0;c<2;++c){input[c].resize(total);expected[c].assign(total,0.f);actual[c].resize(total);for(unsigned i=0;i<total;++i)input[c][i]=noise(random)*1.8f;actual[c]=input[c];}
    dayu::ReferenceLimiter chunks,stream;
    chunks.prepare(48000,2,512);stream.prepare(48000,2,512);
    std::array<std::vector<float>,2> blockOut;
    for(auto &v:blockOut)v.resize(2048);
    for(unsigned start=0;start+2048<=total;start+=2048){
        float *in[2]={input[0].data()+start,input[1].data()+start};
        float *out[2]={blockOut[0].data(),blockOut[1].data()};
        chunks.processReadyChunk(in,out,2,-6.f);
        for(unsigned c=0;c<2;++c)for(unsigned i=0;i<2048 && start+i+latency<total;++i)expected[c][start+i+latency]=blockOut[c][i];
    }
    for(unsigned start=0;start<total;){
        unsigned frames=std::min(total-start,1u+random()%777u);
        float *ptr[2]={actual[0].data()+start,actual[1].data()+start};
        watchAllocations=true;stream.process(ptr,ptr,2,frames,-6.f);watchAllocations=false;
        start+=frames;
    }
    float segmentationDifference=0;
    for(unsigned c=0;c<2;++c)for(unsigned i=0;i<total;++i)segmentationDifference=std::max(segmentationDifference,std::abs(expected[c][i]-actual[c][i]));
    assert(segmentationDifference==0.f);
    assert(allocations==0);
    std::cout << "{\"oracle\":\"naive static-math transcription; not original trial binary\",\"maxAbsoluteError\":"<<largestDifference<<",\"segmentationError\":"<<segmentationDifference<<",\"processingCppAllocations\":"<<allocations<<",\"rates\":[44100,48000,96000],\"channels\":[1,2],\"passed\":true}\n";
}

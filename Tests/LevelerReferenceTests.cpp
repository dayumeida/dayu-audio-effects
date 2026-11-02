#include "../大鱼音频效果器Extension/DSP/LevelerCore.hpp"
#include <array>
#include <cmath>
#include <cstdio>
#include <vector>
#include <algorithm>
#include <cstring>
#include <cstdlib>

static constexpr unsigned rate = 48000, block = 512, seconds = 35;
static float source(unsigned t) {
    const double time = double(t) / rate;
    if (time >= 20 && time < 25) return 0.f;
    const double db = time < 10 ? -36 : (time < 20 ? -12 : -30);
    return float(std::sqrt(2.)*std::pow(10., db/20.)*std::sin(2*M_PI*997*time));
}
int main(int argc, char **argv) {
    float strength = 80, target = -12;
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--strength") == 0 && i+1 < argc) strength = std::strtof(argv[++i], nullptr);
        else if (std::strcmp(argv[i], "--target") == 0 && i+1 < argc) target = std::strtof(argv[++i], nullptr);
    }
    dayu::LevelerCore core; core.prepare(rate);
    core.setParameter(0, target); core.setParameter(1, strength);
    std::array<std::vector<float>,2> in,out;
    for(auto &v:in)v.resize(block);for(auto &v:out)v.resize(block);
    std::vector<double> sum(seconds),peak(seconds);std::vector<unsigned> count(seconds);
    unsigned first=~0u;
    for(unsigned start=0; start<rate*seconds; start+=block){
        const unsigned n=std::min(block,rate*seconds-start);
        for(unsigned i=0;i<n;++i)in[0][i]=in[1][i]=source(start+i);
        float* input[2]={in[0].data(),in[1].data()};float* output[2]={out[0].data(),out[1].data()};
        core.process(input,output,2,n);
        for(unsigned i=0;i<n;++i){
            float value=out[0][i];if(!std::isfinite(value))return 2;
            if(first==~0u && std::abs(value)>1e-7)first=start+i;
            unsigned sec=(start+i)/rate;sum[sec]+=double(value)*value;peak[sec]=std::max(peak[sec],double(std::abs(value)));++count[sec];
        }
    }
    std::printf("{\"strength\":%.5f,\"target\":%.5f,", strength, target);
    std::printf("\"implementation\":\"dayu::LevelerCore\",\"sampleRate\":48000,\"frames\":1680000,\"declaredLatencyFrames\":%u,\"declaredLatencySeconds\":%.9f,\"firstNonzeroFrame\":%u,\"outputPerSecond\":[",core.latencyFrames(),core.latencySeconds(),first);
    for(unsigned sec=0;sec<seconds;++sec){if(sec)std::printf(",");std::printf("{\"second\":%u,\"rmsDB\":%.5f,\"peakDB\":%.5f}",sec,10*std::log10(std::max(sum[sec]/count[sec],1e-24)),20*std::log10(std::max(peak[sec],1e-12)));}
    std::printf("],\"limitations\":\"Comparison target is installed trial AUv2 output, which may include vendor watermark. This does not establish bit-exact equivalence.\"}\n");
}

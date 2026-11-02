// Read-only AUv2 reference probe. Never writes plug-in installation or license data.
#import <AudioToolbox/AudioToolbox.h>
#import <CoreFoundation/CoreFoundation.h>
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <limits>
#include <string>
#include <vector>
#include <unistd.h>
static FILE *report = nullptr;

static double kRate = 48000;
static int quality=0, ptype=0, declip=1;
static float gain=0.857142857f;
static const char* outputPath=nullptr;
static constexpr UInt32 kFrames = 512;
static std::string escape(const std::string &s) {
    std::string r; for (unsigned char c : s) {
        if (c == '"' || c == '\\') r += '\\';
        if (c >= 0x20) r += c;
    } return r;
}
static std::string cfString(CFStringRef s) {
    if (!s) return "";
    char buf[2048] = {};
    CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8);
    return buf;
}
static float sourceSample(uint64_t t) {
 const double sec=double(t)/kRate;
 const double clean=(0.7*std::sin(2*M_PI*997*sec)+0.2*std::sin(2*M_PI*301*sec));
 if (sec<0.5) return float(clean*0.4);
 if (sec<1.5) return float(std::max(-0.35,std::min(0.35,clean)));
 if (sec<2.5) return float(std::max(-0.15,std::min(0.25,clean)));
 return float(clean*0.4);
}
static OSStatus input(void *, AudioUnitRenderActionFlags *, const AudioTimeStamp *ts,
                      UInt32, UInt32 n, AudioBufferList *abl) {
    if (!abl) return kAudio_ParamError;
    const auto start = uint64_t(std::max(0., ts->mSampleTime));
    for (UInt32 b = 0; b < abl->mNumberBuffers; ++b) {
        auto *data = static_cast<float *>(abl->mBuffers[b].mData);
        if (!data) return kAudio_ParamError;
        for (UInt32 i = 0; i < n; ++i) data[i] = sourceSample(start + i);
        abl->mBuffers[b].mDataByteSize = n * sizeof(float);
    }
    return noErr;
}
int main(int argc, char **argv) {
    report = fdopen(dup(STDOUT_FILENO), "w");
    dup2(STDERR_FILENO, STDOUT_FILENO); // Keep plug-in logging out of JSON output.
    bool render = false;
    float requestedStrength = std::numeric_limits<float>::quiet_NaN();
    float requestedTarget = std::numeric_limits<float>::quiet_NaN();
    for (int i = 1; i < argc; ++i) {
        if (std::strcmp(argv[i], "--render") == 0) render = true;
        else if (std::strcmp(argv[i], "--strength") == 0 && i + 1 < argc) requestedStrength = std::strtof(argv[++i], nullptr);
        else if (std::strcmp(argv[i], "--rate")==0 && i+1<argc) kRate=std::atof(argv[++i]);
        else if (std::strcmp(argv[i], "--quality")==0 && i+1<argc) quality=std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--ptype")==0 && i+1<argc) ptype=std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--declip")==0 && i+1<argc) declip=std::atoi(argv[++i]);
        else if (std::strcmp(argv[i], "--gain")==0 && i+1<argc) gain=std::atof(argv[++i]);
        else if (std::strcmp(argv[i], "--out")==0 && i+1<argc) outputPath=argv[++i];
        else if (std::strcmp(argv[i], "--target") == 0 && i + 1 < argc) requestedTarget = std::strtof(argv[++i], nullptr);
    }
    AudioComponentDescription desc{'aufx', 'DcFx', 'Accu', 0, 0};
    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) { std::fprintf(report, "{\"error\":\"component not found\"}\n"); return 1; }
    AudioUnit au = nullptr;
    OSStatus status = AudioComponentInstanceNew(component, &au);
    if (status) { std::fprintf(report, "{\"instantiateStatus\":%d}\n", int(status)); return 1; }
    std::fprintf(report, "{\"probe\":\"ERA4 DeClipper 4.1.11 AUv2\",\"sampleRate\":%.0f,\"mode\":\"%s\",", kRate, render ? "render" : "query");
    std::fflush(report);
    AudioStreamBasicDescription format{};
    format.mSampleRate = kRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = format.mBytesPerFrame = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;
    const OSStatus inFormat = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, sizeof(format));
    const OSStatus outFormat = AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, sizeof(format));
    UInt32 maxFrames = kFrames;
    AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    AURenderCallbackStruct callback{input, nullptr};
    const OSStatus callbackStatus = AudioUnitSetProperty(au, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof(callback));
    UInt32 offline = 1;
    const OSStatus offlineStatus = AudioUnitSetProperty(au, kAudioUnitProperty_OfflineRender, kAudioUnitScope_Global, 0, &offline, sizeof(offline));
    AudioUnitSetParameter(au,3357091,kAudioUnitScope_Global,0,float(quality),0);
    AudioUnitSetParameter(au,195981549,kAudioUnitScope_Global,0,float(ptype),0);
    AudioUnitSetParameter(au,952144203,kAudioUnitScope_Global,0,float(declip),0);
    AudioUnitSetParameter(au,873230368,kAudioUnitScope_Global,0,gain,0);
    Float64 preLatency=-1; UInt32 preSize=sizeof(preLatency);
    AudioUnitGetProperty(au,kAudioUnitProperty_Latency,kAudioUnitScope_Global,0,&preLatency,&preSize);
    const OSStatus initStatus = AudioUnitInitialize(au);
    std::fprintf(report,"\"quality\":%d,\"type\":%d,\"preInitializeLatency\":%.9f,",quality,ptype,preLatency);
    const OSStatus strengthStatus = std::isfinite(requestedStrength)
        ? AudioUnitSetParameter(au, 2, kAudioUnitScope_Global, 0, requestedStrength, 0) : noErr;
    const OSStatus targetStatus = std::isfinite(requestedTarget)
        ? AudioUnitSetParameter(au, 3, kAudioUnitScope_Global, 0, requestedTarget, 0) : noErr;
    std::fprintf(report, "\"strengthSetStatus\":%d,\"targetSetStatus\":%d,", int(strengthStatus), int(targetStatus));
    Float64 latency = -1; UInt32 size = sizeof(latency);
    const OSStatus latencyStatus = AudioUnitGetProperty(au, kAudioUnitProperty_Latency, kAudioUnitScope_Global, 0, &latency, &size);
    std::fprintf(report, "\"inputFormatStatus\":%d,\"outputFormatStatus\":%d,\"callbackStatus\":%d,\"offlineStatus\":%d,\"initializeStatus\":%d,\"latencyStatus\":%d,\"latencySeconds\":%.9f,\"parameters\":[", int(inFormat),int(outFormat),int(callbackStatus),int(offlineStatus),int(initStatus),int(latencyStatus),latency);
    size = 0; Boolean writable = false;
    OSStatus listStatus = AudioUnitGetPropertyInfo(au, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, &size, &writable);
    std::vector<AudioUnitParameterID> ids(size / sizeof(AudioUnitParameterID));
    if (!listStatus && size) listStatus = AudioUnitGetProperty(au, kAudioUnitProperty_ParameterList, kAudioUnitScope_Global, 0, ids.data(), &size);
    bool first = true;
    for (auto id : ids) {
        AudioUnitParameterInfo info{}; size = sizeof(info);
        OSStatus infoStatus = AudioUnitGetProperty(au, kAudioUnitProperty_ParameterInfo, kAudioUnitScope_Global, id, &info, &size);
        AudioUnitParameterValue value = -999;
        OSStatus valueStatus = AudioUnitGetParameter(au, id, kAudioUnitScope_Global, 0, &value);
        std::string name = info.flags & kAudioUnitParameterFlag_HasCFNameString ? cfString(info.cfNameString) : info.name;
        if (!first) std::fprintf(report, ","); first = false;
        std::fprintf(report, "{\"id\":%u,\"name\":\"%s\",\"min\":%.5f,\"max\":%.5f,\"default\":%.5f,\"value\":%.5f,\"unit\":%u,\"infoStatus\":%d,\"valueStatus\":%d}", unsigned(id),escape(name).c_str(),info.minValue,info.maxValue,info.defaultValue,value,unsigned(info.unit),int(infoStatus),int(valueStatus));
        if ((info.flags & kAudioUnitParameterFlag_CFNameRelease) && info.cfNameString) CFRelease(info.cfNameString);
    }
    std::fprintf(report, "],\"parameterListStatus\":%d,\"gainStrings\":[", int(listStatus));
    for(int vi=0;vi<=4;++vi){ float val=float(vi)/4; AudioUnitParameterStringFromValue s{873230368,&val,nullptr}; UInt32 z=sizeof(s); OSStatus er=AudioUnitGetProperty(au,kAudioUnitProperty_ParameterStringFromValue,kAudioUnitScope_Global,0,&s,&z);if(vi)std::fprintf(report,","); std::fprintf(report,"{\"value\":%.4f,\"text\":\"%s\",\"status\":%d}",val,escape(cfString(s.outString)).c_str(),int(er));if(s.outString)CFRelease(s.outString); } std::fprintf(report,"]"); std::fflush(report);
    if (render && !initStatus && !callbackStatus && !inFormat && !outFormat) {
        struct StereoABL { UInt32 n; AudioBuffer b[2]; } buffers{};
        buffers.n = 2;
        std::vector<float> left(kFrames), right(kFrames);
        buffers.b[0] = {1, kFrames * sizeof(float), left.data()};
        buffers.b[1] = {1, kFrames * sizeof(float), right.data()};
        const uint64_t total = uint64_t(4 * kRate);
        std::vector<double> sums(4), peaks(4); std::vector<uint64_t> counts(4);
        FILE* raw=outputPath?std::fopen(outputPath,"wb"):nullptr;
        uint64_t rendered = 0, firstNonzero = UINT64_MAX; OSStatus renderStatus = 0;
        for (uint64_t start = 0; start < total; start += kFrames) {
            const UInt32 n = UInt32(std::min<uint64_t>(kFrames, total - start));
            AudioTimeStamp ts{}; ts.mSampleTime = double(start); ts.mFlags = kAudioTimeStampSampleTimeValid;
            AudioUnitRenderActionFlags flags = 0;
            for (auto &b : buffers.b) b.mDataByteSize = n * sizeof(float);
            renderStatus = AudioUnitRender(au, &flags, &ts, 0, n, reinterpret_cast<AudioBufferList *>(&buffers));
            if (renderStatus) break;
            const auto *data = static_cast<const float *>(buffers.b[0].mData);
            if(raw) std::fwrite(data,sizeof(float),n,raw);
            for (UInt32 i = 0; i < n; ++i) {
                const auto sec = size_t((start + i) / uint64_t(kRate));
                const double sample = data[i];
                if (firstNonzero == UINT64_MAX && std::abs(sample) > 1e-7) firstNonzero = start + i;
                sums[sec] += sample * sample;
                peaks[sec] = std::max(peaks[sec], std::abs(sample)); ++counts[sec];
            }
            rendered += n;
        }
        if(raw) std::fclose(raw);
        std::fprintf(report, ",\"firstNonzeroFrame\":%llu,\"firstNonzeroSeconds\":%.9f", static_cast<unsigned long long>(firstNonzero), double(firstNonzero)/kRate);
        std::fprintf(report, ",\"renderStatus\":%d,\"renderedFrames\":%llu,\"source\":\"0-.5s clean sine mix at 0.4 scale; .5-1.5s clip +/-0.35; 1.5-2.5s clip -0.15/+0.25; remainder clean 0.4 scale\",\"outputPerSecond\":[", int(renderStatus),static_cast<unsigned long long>(rendered));
        for (size_t sec = 0; sec < sums.size(); ++sec) {
            if (sec) std::fprintf(report, ",");
            const double rms = counts[sec] ? std::sqrt(sums[sec] / counts[sec]) : 0;
            std::fprintf(report, "{\"second\":%zu,\"rmsDB\":%.5f,\"peakDB\":%.5f}", sec,20*std::log10(std::max(rms,1e-12)),20*std::log10(std::max(peaks[sec],1e-12)));
        }
        std::fprintf(report, "]");
    }
    AudioUnitUninitialize(au);
    const OSStatus disposeStatus = AudioComponentInstanceDispose(au);
    std::fprintf(report, ",\"disposeStatus\":%d,\"limitations\":\"Trial or watermark may affect output. No license bypass or installation change. Offline synthetic render; no speakers.\"}\n", int(disposeStatus));
    return initStatus ? 1 : 0;
}

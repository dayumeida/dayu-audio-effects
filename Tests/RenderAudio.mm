// Offline validation renderer. File I/O and measurements are outside the AU render callback.
#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <cstdio>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/resource.h>
#if defined(DAYU_DECLIPPER)
#include "../大鱼音频效果器Extension/DSP/Declipper/ERA5DeClipperCore.hpp"
using RenderCore = dayu::ERA5DeClipperCore;
#define DAYU_RENDER_DESCRIPTION @"dayu::ERA5DeClipperCore; bounded ERA5 restoration; explicit physical parameters"
#elif defined(DAYU_LOW_LATENCY)
#include "../大鱼音频效果器Extension/DSP/RealtimeLevelerCore.hpp"
using RenderCore = dayu::RealtimeLevelerCore;
#define DAYU_RENDER_DESCRIPTION @"dayu::RealtimeLevelerCore; causal low-latency; target RMS -18dB / strength 100"
#else
#include "../大鱼音频效果器Extension/DSP/LevelerCore.hpp"
using RenderCore = dayu::LevelerCore;
#define DAYU_RENDER_DESCRIPTION @"dayu::LevelerCore behavioral reconstruction; default target -12dB / strength 80"
#endif

using Clock = std::chrono::steady_clock;
#if defined(DAYU_DECLIPPER)
static constexpr UInt32 kBlock = 512;
#else
static constexpr UInt32 kBlock = 1024;
#endif

static void require(OSStatus status, const char* operation) {
    if (status != noErr) throw std::runtime_error(std::string(operation) + ": OSStatus " + std::to_string(status));
}
static double db(double x) { return 20 * std::log10(std::max(x, 1.e-12)); }
struct AudioFile {
    ExtAudioFileRef ref = nullptr;
    ~AudioFile() { if (ref) ExtAudioFileDispose(ref); }
};
struct StereoABL {
    UInt32 count = 2;
    AudioBuffer buffers[2]{};
    AudioBufferList* get() { return reinterpret_cast<AudioBufferList*>(this); }
    void assign(float* left, float* right, UInt32 frames, UInt32 channels) {
        count = channels;
        buffers[0] = {1, frames * UInt32(sizeof(float)), left};
        buffers[1] = {1, frames * UInt32(sizeof(float)), right};
    }
};
struct ChannelStats {
    double squares = 0, peak = 0;
    uint64_t finite = 0, nonfinite = 0, nan = 0, clipped = 0, zeros = 0;
    void add(float sample) {
        if (!std::isfinite(sample)) { ++nonfinite; nan += std::isnan(sample); return; }
        const double a = std::abs(double(sample));
        squares += double(sample) * sample;
        peak = std::max(peak, a); ++finite;
        clipped += a >= 1.0; zeros += a <= 1.e-9;
    }
    NSDictionary* json() const {
        return @{@"rms_dbfs": @(db(std::sqrt(squares / std::max(uint64_t(1), finite)))),
                 @"peak_dbfs": @(db(peak)), @"peak_linear": @(peak),
                 @"finite_samples": @(finite), @"nonfinite_samples": @(nonfinite),
                 @"nan_samples": @(nan), @"infinity_samples": @(nonfinite - nan),
                 @"samples_abs_ge_1": @(clipped), @"samples_abs_le_1e-9": @(zeros)};
    }
};
struct Bin {
    uint64_t frames = 0, silentFrames = 0;
    std::array<ChannelStats, 2> channel{};
    NSDictionary* json(UInt32 channels) const {
        NSMutableArray* ch = [NSMutableArray array];
        double sum = 0, peak = 0; uint64_t finite = 0;
        for (UInt32 c = 0; c < channels; ++c) {
            [ch addObject:channel[c].json()]; sum += channel[c].squares;
            finite += channel[c].finite; peak = std::max(peak, channel[c].peak);
        }
        return @{@"frames": @(frames), @"silent_frames_all_channels_abs_le_1e-9": @(silentFrames),
                 @"rms_dbfs": @(db(std::sqrt(sum / std::max(uint64_t(1), finite)))),
                 @"peak_dbfs": @(db(peak)), @"channels": ch};
    }
};
struct TrackStats {
    explicit TrackStats(double sampleRate, UInt32 channels) : rate(sampleRate), channels(channels) {}
    double rate; UInt32 channels; Bin total; std::vector<Bin> seconds;
    void add(float* const* audio, UInt32 offset, UInt32 frames) {
        for (UInt32 i = 0; i < frames; ++i) {
            const size_t index = size_t(double(total.frames) / rate);
            if (seconds.size() <= index) seconds.resize(index + 1);
            Bin& bin = seconds[index]; bool silent = true;
            for (UInt32 c = 0; c < channels; ++c) {
                const float sample = audio[c][offset + i];
                total.channel[c].add(sample); bin.channel[c].add(sample);
                silent &= std::isfinite(sample) && std::abs(sample) <= 1.e-9f;
            }
            ++total.frames; ++bin.frames;
            total.silentFrames += silent; bin.silentFrames += silent;
        }
    }
};
static NSDictionary* timesJSON(std::vector<double>& times, double sampleRate) {
    std::sort(times.begin(), times.end());
    if (times.empty()) return @{};
    double sum = 0; for (double time : times) sum += time;
    const double nominalBudget = double(kBlock) / sampleRate * 1.e6;
    const auto overBudget = std::count_if(times.begin(), times.end(), [&](double time) { return time > nominalBudget; });
    const auto p = [&](double fraction) { return times[std::min(times.size()-1, size_t(std::ceil(fraction*times.size()))-1)]; };
    return @{@"block_count": @(times.size()), @"nominal_block_frames": @(kBlock),
             @"p50_us": @(p(.5)), @"p99_us": @(p(.99)), @"max_us": @(times.back()),
             @"nominal_audio_block_budget_us": @(nominalBudget), @"blocks_over_nominal_budget": @(overBudget),
             @"total_core_seconds": @(sum * 1.e-6), @"mean_us": @(sum / times.size())};
}

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        if (argc != 4 && argc != 5) {
            std::fprintf(stderr, "Usage: RenderAudio input output-float.wav metrics.json [limit-seconds]\n"); return 2;
        }
        try {
            AudioFile input, output;
            NSURL* inputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
            require(ExtAudioFileOpenURL((__bridge CFURLRef)inputURL, &input.ref), "Open input");
            AudioStreamBasicDescription source{}; UInt32 size = sizeof(source);
            require(ExtAudioFileGetProperty(input.ref, kExtAudioFileProperty_FileDataFormat, &size, &source), "Read source format");
#if defined(DAYU_DECLIPPER)
            const bool rateSupported = RenderCore::supportsRate(source.mSampleRate);
#else
            const bool rateSupported = source.mSampleRate == 44100;
#endif
            if (source.mChannelsPerFrame < 1 || source.mChannelsPerFrame > 2 || !rateSupported)
                throw std::runtime_error("Unsupported source format; refusing silent resampling/channel conversion");
            AudioStreamBasicDescription client{};
            client.mSampleRate = source.mSampleRate; client.mFormatID = kAudioFormatLinearPCM;
            client.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagsNativeEndian;
            client.mBytesPerPacket = client.mBytesPerFrame = sizeof(float); client.mFramesPerPacket = 1;
            client.mChannelsPerFrame = source.mChannelsPerFrame; client.mBitsPerChannel = 32;
            require(ExtAudioFileSetProperty(input.ref, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client), "Set decoder client format");
            auto fileFormat = client;
            fileFormat.mFormatFlags &= ~kAudioFormatFlagIsNonInterleaved;
            fileFormat.mBytesPerPacket = fileFormat.mBytesPerFrame = sizeof(float) * client.mChannelsPerFrame;
            NSURL* outputURL = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
            require(ExtAudioFileCreateWithURL((__bridge CFURLRef)outputURL, kAudioFileWAVEType, &fileFormat,
                                              nullptr, kAudioFileFlags_EraseFile, &output.ref), "Create WAV");
            require(ExtAudioFileSetProperty(output.ref, kExtAudioFileProperty_ClientDataFormat, sizeof(client), &client), "Set writer client format");
            RenderCore core; core.prepare(client.mSampleRate);
#if defined(DAYU_DECLIPPER)
            if (const char* value = std::getenv("DAYU_REPAIR_QUALITY")) core.setParameter(0, std::atoi(value) ? 1 : 0);
            if (const char* value = std::getenv("DAYU_REPAIR_TYPE")) core.setParameter(2, std::atoi(value) ? 1 : 0);
            if (const char* value = std::getenv("DAYU_REPAIR_GAIN_DB")) core.setParameter(3, std::atof(value));
#endif
            const uint64_t latency = core.latencyFrames();
            const uint64_t limit = argc == 5 ? uint64_t(std::max(0.0, std::atof(argv[4])) * client.mSampleRate) : UINT64_MAX;
            std::array<std::array<float, kBlock>, 2> in{}, out{};
            float* inputs[2] = {in[0].data(), in[1].data()};
            float* outputs[2] = {out[0].data(), out[1].data()};
            StereoABL readABL, writeABL;
            TrackStats inputStats(client.mSampleRate, client.mChannelsPerFrame), outputStats(client.mSampleRate, client.mChannelsPerFrame);
            std::vector<double> times; times.reserve(120000);
            uint64_t processed = 0, lastProgress = 0;
            const auto renderBegin = Clock::now();
            auto process = [&](UInt32 frames, uint64_t sourceEnd) {
                auto begin = Clock::now();
                core.process(inputs, outputs, client.mChannelsPerFrame, frames);
                const auto end = Clock::now();
                times.push_back(std::chrono::duration<double, std::micro>(end - begin).count());
                const uint64_t start = std::max(processed, latency);
                const uint64_t stop = std::min(processed + frames, sourceEnd + latency);
                if (stop > start) {
                    const UInt32 offset = UInt32(start - processed), valid = UInt32(stop - start);
                    outputStats.add(outputs, offset, valid);
                    writeABL.assign(outputs[0] + offset, outputs[1] + offset, valid, client.mChannelsPerFrame);
                    require(ExtAudioFileWrite(output.ref, valid, writeABL.get()), "Write WAV");
                }
                processed += frames;
            };
            while (inputStats.total.frames < limit) {
                UInt32 frames = UInt32(std::min(uint64_t(kBlock), limit - inputStats.total.frames));
                readABL.assign(inputs[0], inputs[1], frames, client.mChannelsPerFrame);
                require(ExtAudioFileRead(input.ref, &frames, readABL.get()), "Decode source");
                if (!frames) break;
                inputStats.add(inputs, 0, frames);
                process(frames, inputStats.total.frames);
                const uint64_t elapsed = uint64_t(double(inputStats.total.frames) / client.mSampleRate);
                if (elapsed >= lastProgress + 120) {
                    lastProgress = elapsed;
                    std::fprintf(stderr, "Rendered source %llu:%02llu, wall %.2fs\n",
                        elapsed / 60, elapsed % 60, std::chrono::duration<double>(Clock::now() - renderBegin).count());
                }
            }
            for (auto& channel : in) channel.fill(0);
            const uint64_t sourceFrames = inputStats.total.frames;
            while (outputStats.total.frames < sourceFrames) {
                const UInt32 frames = UInt32(std::min(uint64_t(kBlock), sourceFrames + latency - processed));
                if (!frames) throw std::runtime_error("Flush accounting stalled");
                process(frames, sourceFrames);
            }
            require(ExtAudioFileDispose(output.ref), "Finalize WAV"); output.ref = nullptr;
            const double wall = std::chrono::duration<double>(Clock::now() - renderBegin).count();
            struct rusage usage{}; getrusage(RUSAGE_SELF, &usage);
            NSMutableArray* perSecond = [NSMutableArray array];
            for (size_t i = 0; i < inputStats.seconds.size(); ++i) {
                [perSecond addObject:@{@"start_second": @(i),
                    @"input": inputStats.seconds[i].json(client.mChannelsPerFrame),
                    @"output": outputStats.seconds[i].json(client.mChannelsPerFrame)}];
            }
            NSMutableArray* parameters = [NSMutableArray array];
            for (uint32_t i = 0; i < RenderCore::parameterCount; ++i) [parameters addObject:@(core.parameter(i))];
            NSDictionary* report = @{
                @"source": inputURL.path, @"output_intermediate": outputURL.path,
                @"algorithm": DAYU_RENDER_DESCRIPTION,
                @"parameter_values_by_address": parameters,
                @"sample_rate_hz": @(client.mSampleRate), @"channels": @(client.mChannelsPerFrame),
                @"source_frames_decoded": @(sourceFrames), @"output_frames_written": @(outputStats.total.frames),
                @"duration_seconds": @(double(sourceFrames) / client.mSampleRate),
                @"algorithm_latency_frames_removed": @(latency),
                @"algorithm_latency_seconds_removed": @(double(latency) / client.mSampleRate),
                @"flush_zero_frames": @(processed - sourceFrames),
                @"render_wall_seconds_including_decode_metrics_and_wav_io": @(wall),
                @"real_time_speed_ratio": @(double(sourceFrames) / client.mSampleRate / wall),
                @"peak_resident_memory_bytes_macOS_getrusage": @(usage.ru_maxrss),
                @"core_process_timing": timesJSON(times, client.mSampleRate),
                @"input_total": inputStats.total.json(client.mChannelsPerFrame),
                @"output_total": outputStats.total.json(client.mChannelsPerFrame),
                @"per_second": perSecond,
                @"notes": @"Float WAV statistics before lossy AAC encoding. Input/output timelines are aligned by trimming reported algorithm latency and zero-flushing the tail. Output statistics count only decoded source duration; no startup/tail padding. RMS is unweighted dBFS, not LUFS. Stereo channels are linked by the algorithm; background and speech are not independently separated. Timing p99 is empirical, not a real-time guarantee."
            };
            NSError* error = nil;
            NSData* json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
            if (!json || ![json writeToFile:[NSString stringWithUTF8String:argv[3]] options:NSDataWritingAtomic error:&error])
                throw std::runtime_error("Write metrics JSON failed");
            std::fprintf(stderr, "Done: %.3fs source, %.3fs wall, %llu frames in/out, latency removed %.6fs, peak RSS %.1f MiB\n",
                double(sourceFrames) / client.mSampleRate, wall, sourceFrames, double(latency) / client.mSampleRate,
                double(usage.ru_maxrss) / 1048576.0);
            return 0;
        } catch (const std::exception& error) {
            std::fprintf(stderr, "RenderAudio failed: %s\n", error.what()); return 1;
        }
    }
}

// Standalone dispatch-overhead experiment, deliberately NOT used by the AU render path.
// Compare equal per-channel RMS + constant gain work on the CPU and GPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Accelerate/Accelerate.h>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <stdexcept>
#include <vector>
#include <sys/sysctl.h>

using Clock = std::chrono::steady_clock;
static constexpr NSUInteger kChannels = 2;
static constexpr NSUInteger kThreads = 256;
static constexpr NSUInteger kWarmup = 50;
static constexpr NSUInteger kIterations = 500;
static constexpr float kGain = 0.73f;

static NSString *cpuName() {
    char value[256] = {};
    size_t bytes = sizeof(value);
    if (sysctlbyname("machdep.cpu.brand_string", value, &bytes, nullptr, 0) == 0) {
        return [NSString stringWithUTF8String:value];
    }
    return @"unknown";
}

static NSDictionary *stats(std::vector<double> durations) {
    std::sort(durations.begin(), durations.end());
    auto percentile = [&](double fraction) {
        const auto index = static_cast<size_t>(std::ceil(fraction * durations.size())) - 1;
        return durations[std::min(index, durations.size() - 1)];
    };
    double total = 0.0;
    for (double duration : durations) total += duration;
    return @{@"p50_us": @(percentile(0.50)), @"p99_us": @(percentile(0.99)),
             @"max_us": @(durations.back()), @"mean_us": @(total / durations.size())};
}

static double micros(Clock::time_point begin, Clock::time_point end) {
    return std::chrono::duration<double, std::micro>(end - begin).count();
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            std::fprintf(stderr, "Usage: MetalDispatchBenchmark /absolute/output.json\n");
            return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            std::fprintf(stderr, "Metal device unavailable\n");
            return 3;
        }
        // Compilation, queue creation and resource allocation are outside timed regions.
        NSString *source = @R"METAL(
            #include <metal_stdlib>
            using namespace metal;
            kernel void rms_and_gain(device const float *input [[buffer(0)]],
                                     device float *output [[buffer(1)]],
                                     device float *rms [[buffer(2)]],
                                     constant uint &frames [[buffer(3)]],
                                     constant float &gain [[buffer(4)]],
                                     uint lane [[thread_index_in_threadgroup]],
                                     uint3 group [[threadgroup_position_in_grid]]) {
                threadgroup float energy[256];
                float sum = 0.0f;
                const uint base = group.x * frames;
                for (uint i = lane; i < frames; i += 256) {
                    const float x = input[base + i];
                    sum += x * x;
                    output[base + i] = x * gain;
                }
                energy[lane] = sum;
                threadgroup_barrier(mem_flags::mem_threadgroup);
                for (uint stride = 128; stride > 0; stride >>= 1) {
                    if (lane < stride) energy[lane] += energy[lane + stride];
                    threadgroup_barrier(mem_flags::mem_threadgroup);
                }
                if (lane == 0) rms[group.x] = sqrt(energy[0] / float(frames));
            }
        )METAL";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        if (!library) {
            std::fprintf(stderr, "Metal compilation failed: %s\n", error.description.UTF8String);
            return 4;
        }
        id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:
            [library newFunctionWithName:@"rms_and_gain"] error:&error];
        if (!pipeline || pipeline.maxTotalThreadsPerThreadgroup < kThreads) {
            std::fprintf(stderr, "Metal pipeline unavailable: %s\n", error.description.UTF8String);
            return 5;
        }
        id<MTLCommandQueue> queue = [device newCommandQueue];
        NSMutableArray *cases = [NSMutableArray array];
        volatile float consumption = 0.0f;

        for (uint32_t frames : {64u, 128u, 512u, 4096u}) {
            const NSUInteger samples = frames * kChannels;
            const NSUInteger bytes = samples * sizeof(float);
            id<MTLBuffer> input = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> output = [device newBufferWithLength:bytes options:MTLResourceStorageModeShared];
            id<MTLBuffer> rms = [device newBufferWithLength:kChannels * sizeof(float)
                                                  options:MTLResourceStorageModeShared];
            if (!input || !output || !rms || !queue) return 6;
            auto *inputSamples = static_cast<float *>(input.contents);
            std::vector<float> cpuOutput(samples);
            float cpuRMS[kChannels] = {};
            for (NSUInteger i = 0; i < samples; ++i) {
                inputSamples[i] = 0.25f * std::sin(float(i) * 0.17f) +
                                  0.13f * std::sin(float(i) * 0.031f);
            }
            auto cpuTask = [&] {
                for (NSUInteger channel = 0; channel < kChannels; ++channel) {
                    float sum = 0.0f;
                    const auto offset = channel * frames;
                    vDSP_svesq(inputSamples + offset, 1, &sum, frames);
                    cpuRMS[channel] = std::sqrt(sum / float(frames));
                    vDSP_vsmul(inputSamples + offset, 1, &kGain, cpuOutput.data() + offset, 1, frames);
                }
            };
            auto gpuTask = [&] {
                @autoreleasepool {
                    id<MTLCommandBuffer> command = [queue commandBuffer];
                    id<MTLComputeCommandEncoder> encoder = [command computeCommandEncoder];
                    [encoder setComputePipelineState:pipeline];
                    [encoder setBuffer:input offset:0 atIndex:0];
                    [encoder setBuffer:output offset:0 atIndex:1];
                    [encoder setBuffer:rms offset:0 atIndex:2];
                    [encoder setBytes:&frames length:sizeof(frames) atIndex:3];
                    [encoder setBytes:&kGain length:sizeof(kGain) atIndex:4];
                    [encoder dispatchThreadgroups:MTLSizeMake(kChannels, 1, 1)
                            threadsPerThreadgroup:MTLSizeMake(kThreads, 1, 1)];
                    [encoder endEncoding];
                    [command commit];
                    // Intentional: measures the end-to-end cost of needing results in this callback.
                    // Production audio callbacks must not synchronously wait for GPU completion.
                    [command waitUntilCompleted];
                    if (command.status == MTLCommandBufferStatusError) {
                        std::fprintf(stderr, "Metal execution failed: %s\n", command.error.description.UTF8String);
                        std::abort();
                    }
                }
            };
            for (NSUInteger i = 0; i < kWarmup; ++i) {
                cpuTask();
                gpuTask();
            }
            std::vector<double> cpuTimes, gpuTimes;
            cpuTimes.reserve(kIterations);
            gpuTimes.reserve(kIterations);
            // Alternate CPU and GPU samples to reduce long-term clock/thermal drift.
            for (NSUInteger i = 0; i < kIterations; ++i) {
                auto begin = Clock::now();
                cpuTask();
                auto end = Clock::now();
                cpuTimes.push_back(micros(begin, end));
                consumption = consumption + cpuRMS[i % kChannels] + cpuOutput[i % samples];
                begin = Clock::now();
                gpuTask();
                end = Clock::now();
                gpuTimes.push_back(micros(begin, end));
            }
            const auto *gpuOutput = static_cast<const float *>(output.contents);
            const auto *gpuRMS = static_cast<const float *>(rms.contents);
            float maxOutputError = 0.0f, maxRMSError = 0.0f;
            for (NSUInteger i = 0; i < samples; ++i)
                maxOutputError = std::max(maxOutputError, std::fabs(cpuOutput[i] - gpuOutput[i]));
            for (NSUInteger channel = 0; channel < kChannels; ++channel)
                maxRMSError = std::max(maxRMSError, std::fabs(cpuRMS[channel] - gpuRMS[channel]));
            const bool valid = maxOutputError <= 1.0e-6f && maxRMSError <= 1.0e-5f;
            if (!valid) {
                std::fprintf(stderr, "CPU/GPU validation failed at %u frames\n", frames);
                return 7;
            }
            NSDictionary *cpuStats = stats(cpuTimes);
            NSDictionary *gpuStats = stats(gpuTimes);
            [cases addObject:@{@"frames_per_channel": @(frames), @"channels": @(kChannels),
                @"audio_budget_us_at_48k": @(double(frames) / 48000.0 * 1.0e6),
                @"cpu_accelerate": cpuStats, @"gpu_synchronous_metal": gpuStats,
                @"max_sample_absolute_error": @(maxOutputError), @"max_rms_absolute_error": @(maxRMSError),
                @"validation_passed": @(valid)}];
            std::fprintf(stderr, "%4u frames: CPU p50 %.3f us / Metal p50 %.3f us, validation PASS\n",
                frames, [cpuStats[@"p50_us"] doubleValue], [gpuStats[@"p50_us"] doubleValue]);
        }
        NSDictionary *report = @{
            @"experiment": @"Per-block stereo RMS plus constant gain: CPU Accelerate versus synchronous Metal",
            @"cpu": cpuName(), @"gpu": device.name,
            @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
            @"sample_rate_hz": @48000, @"warmup_iterations_per_case": @(kWarmup),
            @"measured_iterations_per_case": @(kIterations),
            @"gpu_timing_includes": @"Command buffer/encoder creation, encoding, commit, waitUntilCompleted, autorelease-pool cleanup. Shared storage; no copy or transfer.",
            @"excluded_from_timing": @"Device/queue/pipeline creation, runtime shader compilation, buffer allocation, signal generation, result validation.",
            @"limitations": @"Isolated microbenchmark, not a full leveler or a comparison against original Levelmatic. Does not test pipelined/asynchronous GPU designs, multi-track batching, or performance under DAW/video GPU load. p99 is empirical and not a real-time bound. CPU timings include clock overhead and may be affected by interleaved GPU waits.",
            @"production_policy": @"Benchmark synchronization is intentional and must not be copied into the audio render callback.",
            @"results": cases,
            @"consumption_checksum": @(consumption)
        };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!json || ![json writeToFile:[NSString stringWithUTF8String:argv[1]] options:NSDataWritingAtomic error:&error]) {
            std::fprintf(stderr, "Could not write report: %s\n", error.description.UTF8String);
            return 8;
        }
        return 0;
    }
}

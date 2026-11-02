#include "../大鱼音频效果器Extension/Common/DSP/_______ExtensionAUProcessHelper.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <dlfcn.h>
#include <pthread.h>
#include <execinfo.h>
#include <thread>
#include <vector>

// Observe every malloc-zone allocation, including libraries that bypass malloc().
// Use a fresh audio thread after control-thread preparation to catch lazy TLS work.
static std::atomic<bool> tracking{false};
static std::atomic<uintptr_t> watchedThread{0};
static bool isTrackedThread() noexcept {
    return tracking.load(std::memory_order_relaxed) && watchedThread.load(std::memory_order_relaxed) == reinterpret_cast<uintptr_t>(pthread_self());
}
static std::atomic<size_t> cAllocations{0}, cppAllocations{0};
using MallocLogger = void(*)(uint32_t, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t);
static void* allocationStacks[16][32]{};
static int allocationDepths[16]{};
static void countedAllocation(uint32_t type, uintptr_t, uintptr_t, uintptr_t, uintptr_t, uint32_t) {
    if (isTrackedThread() && (type & 2)) {
        const size_t index = cAllocations++;
        if (index < 16) {
            tracking = false;
            allocationDepths[index] = backtrace(allocationStacks[index], 32);
            tracking = true;
        }
    }
}
void* operator new(size_t n) { if (isTrackedThread()) ++cppAllocations; if (auto p = malloc(n)) return p; throw std::bad_alloc(); }
void* operator new[](size_t n) { return ::operator new(n); }
void operator delete(void* p) noexcept { free(p); }
void operator delete[](void* p) noexcept { free(p); }
struct Buffers { UInt32 count; AudioBuffer buffers[2]; };

int main(int argc, char** argv) {
    if (argc < 2) return 2;
    auto loggerSlot = reinterpret_cast<MallocLogger*>(dlsym(RTLD_DEFAULT, "malloc_logger"));
    if (!loggerSlot) { std::fprintf(stderr, "malloc_logger unavailable; allocation check cannot pass\n"); return 4; }
    const auto previousLogger = *loggerSlot;
    *loggerSlot = countedAllocation;
    watchedThread = reinterpret_cast<uintptr_t>(pthread_self());
    tracking = true;
    auto* positiveControl = static_cast<volatile char*>(malloc(97));
    *positiveControl = 1;
    free(const_cast<char*>(positiveControl));
    tracking = false;
    if (!cAllocations) { *loggerSlot = previousLogger; return 5; }
    cAllocations = 0;
    const uint32_t subtype = argc > 2 ? uint32_t(strtoul(argv[2], nullptr, 16)) : 0x6479646e;
    auto helper = AUProcessHelper::createForSubtype(subtype);
    if (!helper || !helper->configureResources(argv[1]) || !helper->allocate(48000, 2, 16384)) return 3;
    const auto render = helper->internalRenderBlock();
    AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags*, const AudioTimeStamp* t, AUAudioFrameCount n, NSInteger, AudioBufferList* list) {
        for (UInt32 c = 0; c < 2; ++c) {
            auto* data = static_cast<float*>(list->mBuffers[c].mData);
            for (UInt32 i = 0; i < n; ++i) {
                const double s = t->mSampleTime + i;
                data[i] = std::clamp(float(.5 * sin(s * .025) + .2 * sin(s * .059)), -.3f, .3f) * (c ? .7f : 1.f);
            }
        }
        return noErr;
    };
    bool valid = true;
    std::printf("{\"sampleRate\":48000,\"subtype\":\"%08x\",\"mallocLoggerPositiveControl\":true,\"freshRenderThreads\":true,\"blocks\":[", subtype);
    bool first = true;
    for (const uint32_t block : {32u, 128u, 512u, 16384u}) {
        helper->reset();
        std::vector<double> times((144000 + block - 1) / block);
        std::thread audio([&] {
            tracking = false;
            watchedThread = reinterpret_cast<uintptr_t>(pthread_self());
            for (uint32_t start = 0, b = 0; start < 144000; start += block, ++b) {
                const uint32_t n = std::min(block, 144000 - start);
                AudioTimeStamp time{}; time.mFlags = kAudioTimeStampSampleTimeValid; time.mSampleTime = start;
                AudioUnitRenderActionFlags flags = 0;
                Buffers output{2, {{1, 0, nullptr}, {1, 0, nullptr}}};
                const auto begin = std::chrono::steady_clock::now();
                tracking = true;
                const auto status = render(&flags, &time, n, 0, reinterpret_cast<AudioBufferList*>(&output), nullptr, pull);
                tracking = false;
                times[b] = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
                valid &= status == noErr;
                if (status == noErr) for (uint32_t c = 0; c < 2; ++c) for (uint32_t i = 0; i < n; ++i)
                    valid &= std::isfinite(static_cast<float*>(output.buffers[c].mData)[i]);
            }
        });
        audio.join();
        std::sort(times.begin(), times.end());
        if (!first) std::printf(","); first = false;
        std::printf("{\"frames\":%u,\"budgetMs\":%.6f,\"p99Ms\":%.6f,\"maxMs\":%.6f}", block, block / 48., times[size_t((times.size() - 1) * .99)], times.back());
    }
    std::printf("],\"cAllocations\":%zu,\"cppAllocations\":%zu,\"finiteAudio\":%s,\"limitations\":\"Offline synthetic pulls under current system load; not FCP waveform timing or a worst-case scheduling guarantee\"}\n", cAllocations.load(), cppAllocations.load(), valid ? "true" : "false");
    AUProcessHelper::destroy(helper);
    *loggerSlot = previousLogger;
    for (size_t i = 0; i < std::min(size_t(16), cAllocations.load()); ++i) {
        std::fprintf(stderr, "Allocation stack %zu:\n", i);
        backtrace_symbols_fd(allocationStacks[i], allocationDepths[i], 2);
    }
    return !valid || cAllocations || cppAllocations;
}

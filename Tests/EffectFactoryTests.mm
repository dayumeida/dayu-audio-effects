#include "../大鱼音频效果器Extension/Common/DSP/_______ExtensionAUProcessHelper.hpp"
#include <cstdio>
#include <cstdlib>
#include <new>
#include <cstring>
#include "../大鱼音频效果器Extension/DSP/LevelerCore.hpp"
#include "../大鱼音频效果器Extension/DSP/RealtimeLevelerCore.hpp"

static bool trackAllocations = false;
static size_t allocations = 0;
void* operator new(size_t n) { if (trackAllocations) ++allocations; if (auto p = std::malloc(n)) return p; throw std::bad_alloc(); }
void* operator new[](size_t n) { return ::operator new(n); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
static void check(bool ok, const char* reason) { if (!ok) { std::fprintf(stderr, "%s\n", reason); std::exit(1); } }
struct Buffers { UInt32 n; AudioBuffer buffers[2]; };

template<class Core> static void verify(uint32_t subtype) {
    auto helper = AUProcessHelper::createForSubtype(subtype);
    check(helper && helper->effectSubtype() == subtype, "wrong effect identity");
    check(helper->parameterCount() == Core::parameterCount, "wrong parameter schema");
    for (uint32_t p = 0; p < Core::parameterCount; ++p)
        check(helper->defaultParameter(p) == Core::defaults[p] && helper->getParameter(p) == Core::defaults[p], "wrong defaults");
    Core direct;
    direct.prepare(48000);
    check(helper->allocate(48000, 2, 1024), "allocation failed");
    float input[2][1024]{}, expected[2][1024]{};
    float* ins[]{input[0], input[1]};
    float* outs[]{expected[0], expected[1]};
    float* left = input[0]; float* right = input[1];
    AURenderPullInputBlock pull = ^AUAudioUnitStatus(AudioUnitRenderActionFlags*, const AudioTimeStamp*, AUAudioFrameCount n, NSInteger, AudioBufferList* list) {
        std::memcpy(list->mBuffers[0].mData, left, n * sizeof(float));
        std::memcpy(list->mBuffers[1].mData, right, n * sizeof(float));
        return noErr;
    };
    auto render = helper->internalRenderBlock();
    uint32_t random = 7, start = 0;
    for (uint32_t block = 0; block < 2400; ++block) {
        const uint32_t n = 1 + (block * 137) % 1024;
        if (block == 1300) { start += 999999; direct.reset(); }
        for (uint32_t i = 0; i < n; ++i) {
            random = random * 1664525 + 1013904223;
            input[0][i] = (float(random >> 8) / 16777216.f - .5f) * (block < 600 ? .01f : .3f);
            input[1][i] = input[0][i] * .37f;
        }
        if (block == 1600) { helper->setParameter(1, 45); direct.setParameter(1, 45); }
        if (block == 1900) { helper->setBypass(true); direct.setBypass(true); }
        direct.process(ins, outs, 2, n);
        Buffers output{2, {{1, 0, nullptr}, {1, 0, nullptr}}};
        AudioTimeStamp time{}; time.mFlags = kAudioTimeStampSampleTimeValid; time.mSampleTime = start;
        AudioUnitRenderActionFlags flags = 0;
        trackAllocations = true;
        auto status = render(&flags, &time, n, 0, reinterpret_cast<AudioBufferList*>(&output), nullptr, pull);
        trackAllocations = false;
        check(status == noErr, "render failed");
        for (uint32_t c = 0; c < 2; ++c)
            check(std::memcmp(output.buffers[c].mData, expected[c], n * sizeof(float)) == 0, "factory changed algorithm output");
        start += n;
    }
    AUProcessHelper::destroy(helper);
}

int main() {
    check(!AUProcessHelper::createForSubtype(0), "unknown subtype accepted");
    check(!AUProcessHelper::createForSubtype(0x64797a7a), "unknown effect mapped to leveler");
    verify<dayu::LevelerCore>(0x64796c76);
    verify<dayu::RealtimeLevelerCore>(0x64796c6c);
    check(allocations == 0, "C++ allocation during render or seek reset");
    std::puts("{\"passed\":true,\"factoryOutputBitExactToExistingCores\":true,\"unknownSubtypesRejected\":true,\"randomBlocksAndSeek\":true,\"renderCppAllocations\":0}");
}

#pragma once
#include <AudioToolbox/AudioToolbox.h>
#include <array>
#include <atomic>
#include <variant>
#include <stdexcept>
#include "EffectKind.hpp"
#include "_______ExtensionParameterAddresses.h"
#include "LevelerCore.hpp"
#include "RealtimeLevelerCore.hpp"
#include "AudioDenoiseCore.hpp"
#include "Declipper/ERA5DeClipperCore.hpp"

// Mode is fixed at construction: each FCP effect has a stable latency contract.
class _______ExtensionDSPKernel {
    using Core = std::variant<dayu::LevelerCore, dayu::RealtimeLevelerCore, dayu::AudioDenoiseCore, dayu::ERA5DeClipperCore>;
    static Core makeCore(dayu::EffectKind kind) {
        switch (kind) {
            case dayu::EffectKind::referenceLeveler: return Core(std::in_place_type<dayu::LevelerCore>);
            case dayu::EffectKind::realtimeLeveler: return Core(std::in_place_type<dayu::RealtimeLevelerCore>);
            case dayu::EffectKind::audioDenoise: return Core(std::in_place_type<dayu::AudioDenoiseCore>);
            case dayu::EffectKind::era5Declipper: return Core(std::in_place_type<dayu::ERA5DeClipperCore>);
        }
        throw std::invalid_argument("Unsupported audio effect");
    }
    template<class F> decltype(auto) withCore(F&& f) { return std::visit(std::forward<F>(f), core_); }
    template<class F> decltype(auto) withCore(F&& f) const { return std::visit(std::forward<F>(f), core_); }
public:
    explicit _______ExtensionDSPKernel(dayu::EffectKind kind = dayu::EffectKind::referenceLeveler)
        : kind_(kind), core_(makeCore(kind)) {
        static_assert(dayu::LevelerCore::parameterCount <= maximumParameters);
        static_assert(dayu::RealtimeLevelerCore::parameterCount <= maximumParameters);
        static_assert(dayu::AudioDenoiseCore::parameterCount <= maximumParameters);
        static_assert(dayu::ERA5DeClipperCore::parameterCount <= maximumParameters);
        for (uint32_t i = 0; i < parameterCount(); ++i) {
            const float value = defaultParameter(i);
            parameters_[i].store(value, std::memory_order_relaxed); synchronized_[i] = value;
        }
        for (uint32_t i = 0; i < 4; ++i) meters_[i].store(i < 2 ? -120.f : 0.f);
        for (auto& stream : waveforms_) for (auto& v : stream) v.store(0);
        for (auto& v : previewInput_) v.store(0);
    }
    bool configureResources(const char* modelPath) {
        if (kind_ != dayu::EffectKind::audioDenoise) return true;
        auto& core = std::get<dayu::AudioDenoiseCore>(core_);
        return core.modelReady() || (modelPath && core.loadModel(modelPath));
    }
    bool supportsRate(double rate) const noexcept {
        return kind_ == dayu::EffectKind::era5Declipper ? dayu::ERA5DeClipperCore::supportsRate(rate)
            : std::isfinite(rate) && rate >= 8000 && rate <= 384000;
    }
    bool resourcesReady() const noexcept {
        return kind_ != dayu::EffectKind::audioDenoise || std::get<dayu::AudioDenoiseCore>(core_).modelReady();
    }
    void initialize(double sampleRate) {
        const double rate = validRate(sampleRate);
        sampleRate_.store(rate, std::memory_order_relaxed);
        previewHop_ = std::max(1u, uint32_t(rate * .01));
        withCore([&](auto& core) { core.prepare(rate); });
        reset();
    }
    void deInitialize() noexcept {}
    void reset() noexcept {
        withCore([&](auto& core) { core.setBypass(isBypassed()); core.reset(); });
        for (uint32_t i = 0; i < parameterCount(); ++i) {
            const float value = parameters_[i].load(std::memory_order_relaxed);
            applyParameter(i, value); synchronized_[i] = value;
        }
        framesReceived_.store(0, std::memory_order_relaxed);
        previewCount_ = previewPosition_ = 0; previewPeak_ = 0; previewHistory_.fill(0);
        for (auto& v : previewInput_) v.store(0, std::memory_order_relaxed);
        for (auto& stream : waveforms_) for (auto& v : stream) v.store(0, std::memory_order_relaxed);
        for (uint32_t i = 0; i < 4; ++i) meters_[i].store(i < 2 ? -120.f : 0.f, std::memory_order_relaxed);
    }
    bool isBypassed() const noexcept { return bypass_.load(std::memory_order_relaxed); }
    void setBypass(bool value) noexcept { bypass_.store(value, std::memory_order_relaxed); }
    uint32_t effectSubtype() const noexcept { return static_cast<uint32_t>(kind_); }
    uint32_t parameterCount() const noexcept { return withCore([](const auto& core) { return core.parameterCount; }); }
    float defaultParameter(uint32_t id) const noexcept {
        return withCore([&](const auto& core) { return id < core.parameterCount ? core.defaults[id] : 0.f; });
    }
    void setParameter(AUParameterAddress address, AUValue value) noexcept {
        if (address < parameterCount() && isWritable(uint32_t(address))) parameters_[address].store(sanitize(uint32_t(address), value), std::memory_order_relaxed);
    }
    AUValue getParameter(AUParameterAddress address) const noexcept {
        if (kind_ == dayu::EffectKind::audioDenoise && address == 7) return meters_[3].load(std::memory_order_relaxed) * 100;
        return address < parameterCount() ? parameters_[address].load(std::memory_order_relaxed) : 0;
    }
    AUAudioFrameCount maximumFramesToRender() const noexcept { return maxFrames_; }
    void setMaximumFramesToRender(const AUAudioFrameCount& value) noexcept { maxFrames_ = value; }
    double latencySecondsForRate(double sampleRate) const noexcept {
        const double rate = validRate(sampleRate);
        switch (kind_) {
            case dayu::EffectKind::realtimeLeveler: return std::max(1.0, std::round(rate * .005)) / rate;
            case dayu::EffectKind::referenceLeveler: return std::ceil(rate * 5 / 2048) * 3072 / rate;
            case dayu::EffectKind::audioDenoise: return dayu::AudioDenoiseCore::latencyFramesForRate(rate) / rate;
            case dayu::EffectKind::era5Declipper: return dayu::ERA5DeClipperCore::latencyFramesForRate(rate) / rate;
        }
        return 0;
    }
    double latencySeconds() const noexcept { return latencySecondsForRate(sampleRate_.load(std::memory_order_relaxed)); }
    double tailSeconds() const noexcept { return latencySeconds(); }
    bool hasReceivedAudio() const noexcept { return framesReceived_.load(std::memory_order_relaxed) != 0; }
    double warmupRemainingSeconds() const noexcept {
        const double rate = sampleRate_.load(std::memory_order_relaxed);
        return std::max(0.0, latencySecondsForRate(rate) - framesReceived_.load(std::memory_order_relaxed) / rate);
    }
    float getMeter(uint32_t id) const noexcept { return id < 4 ? meters_[id].load(std::memory_order_relaxed) : 0; }
    float getWaveformPoint(uint32_t stream, uint32_t index) const noexcept {
        if (stream > 1 || index >= 256) return 0;
        if (stream == 0 && warmupRemainingSeconds() > 0)
            return previewInput_[index].load(std::memory_order_relaxed);
        return waveforms_[stream][index].load(std::memory_order_relaxed);
    }
    void process(float* const* inputs, float* const* outputs, uint32_t channels, AUAudioFrameCount frames) noexcept {
        synchronizeParameters();
        // Live input preview is independent of DSP lookahead. Capture before an
        // in-place process could overwrite input. Once warm, publish aligned pairs.
        if (warmupRemainingSeconds() > 0) {
            for (uint32_t i = 0; i < frames; ++i) {
                for (uint32_t c = 0; c < channels; ++c)
                    if (std::isfinite(inputs[c][i])) previewPeak_ = std::max(previewPeak_, std::abs(inputs[c][i]));
                if (++previewCount_ == previewHop_) {
                    previewHistory_[previewPosition_] = std::min(1.f, previewPeak_);
                    previewPosition_ = (previewPosition_ + 1) % 256;
                    for (uint32_t p = 0; p < 256; ++p)
                        previewInput_[p].store(previewHistory_[(previewPosition_ + p) % 256], std::memory_order_relaxed);
                    previewPeak_ = 0; previewCount_ = 0;
                }
            }
        }
        withCore([&](auto& core) {
            core.setBypass(isBypassed()); core.process(inputs, outputs, channels, frames);
            for (uint32_t stream = 0; stream < 2; ++stream) for (uint32_t i = 0; i < 256; ++i)
                waveforms_[stream][i].store(core.waveform(stream, i), std::memory_order_relaxed);
            for (uint32_t i = 0; i < 4; ++i)
                meters_[i].store(core.meter(i), std::memory_order_relaxed);
        });
        float peak = 0;
        for (uint32_t c = 0; c < channels; ++c) for (uint32_t i = 0; i < frames; ++i) peak = std::max(peak, std::abs(outputs[c][i]));
        if (frames) meters_[1].store(20.f * std::log10(std::max(1.e-6f, peak)), std::memory_order_relaxed);
        framesReceived_.fetch_add(frames, std::memory_order_relaxed);
    }
    void handleOneEvent(AUEventSampleTime, const AURenderEvent* event) noexcept {
        if (!event) return;
        if (event->head.eventType == AURenderEventParameter || event->head.eventType == AURenderEventParameterRamp) {
            const auto& p = event->parameter;
            if (p.parameterAddress >= parameterCount() || !isWritable(uint32_t(p.parameterAddress))) return;
            const uint32_t id = uint32_t(p.parameterAddress);
            const float value = sanitize(id, p.value);
            parameters_[id].store(value, std::memory_order_relaxed); synchronized_[id] = value;
            if (event->head.eventType == AURenderEventParameterRamp) {
                withCore([&](auto& core) { core.rampParameter(id, value, p.rampDurationSampleFrames); });
            } else applyParameter(id, value);
        }
    }
private:
    bool isWritable(uint32_t id) const noexcept { return kind_ != dayu::EffectKind::audioDenoise || (id != 0 && id != 7); }
    static double validRate(double rate) noexcept { return std::isfinite(rate) && rate >= 8000 && rate <= 384000 ? rate : 48000; }
    float sanitize(uint32_t id, float value) const noexcept {
        return withCore([&](const auto& core) { return core.sanitize(id, value); });
    }
    void applyParameter(uint32_t id, float value) noexcept {
        withCore([&](auto& core) { core.setParameter(id, value); });
    }
    void synchronizeParameters() noexcept {
        for (uint32_t i = 0; i < parameterCount(); ++i) {
            const float value = parameters_[i].load(std::memory_order_relaxed);
            if (value != synchronized_[i]) { applyParameter(i, value); synchronized_[i] = value; }
        }
    }
    static_assert(std::atomic<float>::is_always_lock_free && std::atomic<uint64_t>::is_always_lock_free);
    const dayu::EffectKind kind_;
    Core core_;
    static constexpr uint32_t maximumParameters = 32;
    std::array<std::atomic<float>, maximumParameters> parameters_{};
    std::array<float, maximumParameters> synchronized_{};
    std::array<std::atomic<float>, 4> meters_;
    std::array<std::array<std::atomic<float>, 256>, 2> waveforms_{};
    std::array<std::atomic<float>, 256> previewInput_{};
    std::array<float, 256> previewHistory_{};
    uint32_t previewPosition_ = 0, previewCount_ = 0, previewHop_ = 480;
    float previewPeak_ = 0;
    std::atomic<uint64_t> framesReceived_{0};
    std::atomic<double> sampleRate_{48000};
    std::atomic<bool> bypass_{false};
    AUAudioFrameCount maxFrames_ = 1024;
};

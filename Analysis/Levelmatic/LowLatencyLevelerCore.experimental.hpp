#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>

// Original implementation of a causal speech leveler. No vendor code/assets.
// Only prepare() allocates. All other methods are render-thread-only.
namespace dayu {
class LevelerCore {
public:
    static constexpr uint32_t parameterCount = 7;
    inline static constexpr std::array<float, parameterCount> defaults = {-18, 100, 18, 600, -55, 0, -1};
    inline static constexpr std::array<float, parameterCount> minima = {-30, 0, 0, 100, -80, -12, -12};
    inline static constexpr std::array<float, parameterCount> maxima = {-9, 100, 24, 2000, -30, 12, 0};
    static float sanitize(uint32_t id, float v) noexcept {
        return id < parameterCount ? (std::isfinite(v) ? std::clamp(v, minima[id], maxima[id]) : defaults[id]) : 0;
    }

    void prepare(double rate) {
        sampleRate_ = std::isfinite(rate) && rate >= 8000 && rate <= 384000 ? rate : 48000;
        hop_ = std::max(1u, uint32_t(std::lround(sampleRate_ * 0.01)));
        delay_ = std::max(1u, uint32_t(std::lround(sampleRate_ * 0.005)));
        capacity_ = delay_ + 1;
        for (auto& b : wet_) b.assign(capacity_, 0);
        for (auto& b : dry_) b.assign(capacity_, 0);
        peaks_.assign(capacity_ + 1, {});
        attack_ = float(std::exp(-1.0 / (sampleRate_ * .001)));
        release_ = float(std::exp(-1.0 / (sampleRate_ * .080)));
        bypassStep_ = float(1.0 / (sampleRate_ * .005));
        reset();
    }

    void reset() noexcept {
        for (auto& b : wet_) std::fill(b.begin(), b.end(), 0);
        for (auto& b : dry_) std::fill(b.begin(), b.end(), 0);
        history_.fill(0);
        head_ = tail_ = write_ = ticks_ = historyPosition_ = historyCount_ = 0;
        sequence_ = 0;
        hopEnergy_ = historyEnergy_ = outputEnergy_ = 0;
        silentSamples_ = 0;
        levelDb_ = 0;
        levelGain_ = levelTarget_ = outputGain_ = outputTarget_ = limiterGain_ = 1;
        levelStep_ = outputStep_ = 0;
        bypassMix_ = bypass_ ? 1.f : 0.f;
        rampMask_ = 0;
        meters_ = {-120, -120, 0, 0};
    }

    void setParameter(uint32_t id, float value) noexcept {
        if (id >= parameterCount) return;
        values_[id] = sanitize(id, value);
        rampMask_ &= ~(1u << id);
    }
    void rampParameter(uint32_t id, float value, uint32_t frames) noexcept {
        if (id >= parameterCount) return;
        value = sanitize(id, value);
        if (frames == 0) { setParameter(id, value); return; }
        ramps_[id] = {value, (value - values_[id]) / float(frames), frames};
        rampMask_ |= 1u << id;
    }
    float parameter(uint32_t id) const noexcept { return id < parameterCount ? values_[id] : 0; }
    void setBypass(bool value) noexcept { bypass_ = value; }
    uint32_t latencyFrames() const noexcept { return delay_; }
    double latencySeconds() const noexcept { return delay_ / sampleRate_; }
    float meter(uint32_t id) const noexcept { return id < meters_.size() ? meters_[id] : 0; }

    // Supports disjoint and in-place planar buffers. Both stereo channels share gain.
    void process(float* const* inputs, float* const* outputs, uint32_t channels, uint32_t frames) noexcept {
        if (channels < 1 || channels > 2 || capacity_ == 0) return;
        for (uint32_t i = 0; i < frames; ++i) {
            if (rampMask_) advanceRamps();
            if (ticks_ == 0) {
                // Recalculate parameter-derived constants only at the control rate.
                ceiling_ = dbToGain(values_[6]);
            }
            levelGain_ += levelStep_;
            outputGain_ += outputStep_;
            float gain = levelGain_ * outputGain_;
            float linkedInput = 0, linkedWet = 0;
            std::array<float, 2> in{};
            for (uint32_t c = 0; c < channels; ++c) {
                const float raw = inputs[c][i];
                // Contain malformed host samples and avoid denormal DSP state.
                in[c] = std::isfinite(raw) ? std::clamp(raw, -64.f, 64.f) : 0.f;
                if (std::abs(in[c]) < 1.e-20f) in[c] = 0;
                linkedInput = std::max(linkedInput, std::abs(in[c]));
                wet_[c][write_] = in[c] * gain;
                dry_[c][write_] = in[c];
                linkedWet = std::max(linkedWet, std::abs(wet_[c][write_]));
            }
            hopEnergy_ += double(linkedInput) * linkedInput;
            // Monotonic peak queue: amortized O(1), includes current + delayed sample.
            while (head_ != tail_ && peaks_[head_].index + delay_ < sequence_) head_ = next(head_);
            while (head_ != tail_ && peaks_[previous(tail_)].value <= linkedWet) tail_ = previous(tail_);
            peaks_[tail_] = {sequence_, linkedWet};
            tail_ = next(tail_);
            const float futurePeak = peaks_[head_].value;
            const float requested = futurePeak > ceiling_ ? ceiling_ / futurePeak : 1.f;
            const float coeff = requested < limiterGain_ ? attack_ : release_;
            limiterGain_ = requested + coeff * (limiterGain_ - requested);
            // Read the sample exactly delay_ frames behind, including initial zeros.
            const uint32_t read = (write_ + 1) % capacity_;
            float delayedPeak = 0;
            for (uint32_t c = 0; c < channels; ++c) delayedPeak = std::max(delayedPeak, std::abs(wet_[c][read]));
            // Final linked sample-peak guard. This is not an oversampled true-peak limiter.
            const float safety = delayedPeak > ceiling_ ? ceiling_ / delayedPeak : 1.f;
            const float limitedGain = std::min(limiterGain_, safety);
            const float bypassTarget = bypass_ ? 1.f : 0.f;
            bypassMix_ += std::clamp(bypassTarget - bypassMix_, -bypassStep_, bypassStep_);
            float outputPeak = 0;
            for (uint32_t c = 0; c < channels; ++c) {
                const float wet = wet_[c][read] * limitedGain;
                const float value = wet + bypassMix_ * (dry_[c][read] - wet);
                outputs[c][i] = value;
                outputPeak = std::max(outputPeak, std::abs(value));
            }
            outputEnergy_ += double(outputPeak) * outputPeak;
            write_ = read;
            ++sequence_;
            if (++ticks_ == hop_) updateControl();
        }
    }

private:
    struct Peak { uint64_t index = 0; float value = 0; };
    struct Ramp { float target = 0, step = 0; uint32_t remaining = 0; };
    uint32_t next(uint32_t p) const noexcept { return p + 1 == peaks_.size() ? 0 : p + 1; }
    uint32_t previous(uint32_t p) const noexcept { return p == 0 ? uint32_t(peaks_.size() - 1) : p - 1; }
    static float dbToGain(float db) noexcept { return std::pow(10.f, db * .05f); }
    static float powerToDb(double p) noexcept { return float(10 * std::log10(std::max(1.e-12, p))); }
    void advanceRamps() noexcept {
        for (uint32_t id = 0; id < parameterCount; ++id) if (rampMask_ & (1u << id)) {
            auto& r = ramps_[id];
            values_[id] += r.step;
            if (--r.remaining == 0) { values_[id] = r.target; rampMask_ &= ~(1u << id); }
        }
    }
    void updateControl() noexcept {
        const double energy = hopEnergy_ / hop_;
        historyEnergy_ -= history_[historyPosition_];
        history_[historyPosition_] = energy;
        historyEnergy_ += energy;
        historyPosition_ = (historyPosition_ + 1) % history_.size();
        historyCount_ = std::min(historyCount_ + 1u, uint32_t(history_.size()));
        const float shortDb = powerToDb(energy);
        const float rmsDb = powerToDb(historyEnergy_ / historyCount_);
        float desiredDb = levelDb_;
        if (shortDb > values_[4]) {
            silentSamples_ = 0;
            const float activity = std::clamp((shortDb - values_[4]) / 6.f, 0.f, 1.f);
            desiredDb = std::clamp(values_[0] - rmsDb, -36.f, values_[2]) * (values_[1] * .01f) * activity;
        } else {
            silentSamples_ += hop_;
            // Hold across word gaps. Never chase silence toward maximum boost.
            if (silentSamples_ > sampleRate_ * .25) desiredDb = 0;
        }
        const float seconds = values_[3] * .001f;
        const float timeConstant = desiredDb < levelDb_ ? std::max(.020f, seconds * .15f) : seconds;
        const float coefficient = float(std::exp(-double(hop_) / (sampleRate_ * timeConstant)));
        levelDb_ = desiredDb + coefficient * (levelDb_ - desiredDb);
        levelGain_ = levelTarget_; // absorb floating point ramp drift
        levelTarget_ = dbToGain(levelDb_);
        levelStep_ = (levelTarget_ - levelGain_) / hop_;
        outputGain_ = outputTarget_;
        outputTarget_ = dbToGain(values_[5]);
        outputStep_ = (outputTarget_ - outputGain_) / hop_;
        meters_[0] = rmsDb;
        meters_[1] = powerToDb(outputEnergy_ / hop_);
        meters_[2] = levelDb_;
        meters_[3] = 20.f * std::log10(std::max(1.e-6f, limiterGain_));
        hopEnergy_ = outputEnergy_ = 0;
        ticks_ = 0;
    }
    std::array<float, parameterCount> values_ = defaults;
    std::array<Ramp, parameterCount> ramps_{};
    uint32_t rampMask_ = 0;
    std::array<std::vector<float>, 2> wet_, dry_;
    std::vector<Peak> peaks_;
    std::array<double, 30> history_{};
    std::array<float, 4> meters_ = {-120, -120, 0, 0};
    double sampleRate_ = 48000, hopEnergy_ = 0, historyEnergy_ = 0, outputEnergy_ = 0;
    uint64_t sequence_ = 0, silentSamples_ = 0;
    uint32_t hop_ = 480, delay_ = 240, capacity_ = 0, write_ = 0, ticks_ = 0;
    uint32_t head_ = 0, tail_ = 0, historyPosition_ = 0, historyCount_ = 0;
    float levelDb_ = 0, levelGain_ = 1, levelTarget_ = 1, levelStep_ = 0;
    float outputGain_ = 1, outputTarget_ = 1, outputStep_ = 0;
    float limiterGain_ = 1, attack_ = 0, release_ = 0, ceiling_ = .89125094f;
    bool bypass_ = false;
    float bypassMix_ = 0, bypassStep_ = 1;
};
}

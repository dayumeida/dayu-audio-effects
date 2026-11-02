#pragma once
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <vector>
#include "ReferenceLimiter.hpp"

namespace dayu {
// Behavioral reconstruction from the installed ARM64 build. See Analysis/Levelmatic.
// The 5 s analysis window, two normalization passes and original strength law are
// deliberately retained. No vendor machine code, license logic or watermark.
class LevelerCore {
public:
    static constexpr uint32_t parameterCount = 7;
    inline static constexpr std::array<float, 7> defaults = {-3, 80, 24.608978f, 1000, -36.6f, 0, 0};
    inline static constexpr std::array<float, 7> minima = {-24, 0, 0, 100, -80, -12, -12};
    inline static constexpr std::array<float, 7> maxima = {0, 100, 30, 2000, -20, 12, 0};
    static float sanitize(uint32_t i, float v) noexcept {
        return i < 7 ? (std::isfinite(v) ? std::clamp(v, minima[i], maxima[i]) : defaults[i]) : 0;
    }
    void prepare(double rate) {
        rate_ = std::isfinite(rate) && rate >= 8000 && rate <= 384000 ? rate : 48000;
        window_ = uint32_t(std::ceil(rate_ * 5.0 / 2048)) * 2048;
        half_ = window_ / 2;
        delay_ = window_ + half_;
        frame_ = std::max(2u, uint32_t(rate_ * .05));
        bins_ = std::min(maxBins - 1, (window_ - 1) / frame_);
        limiter_.prepare(rate_, 2, 1024);
        // Align source frame zero with the reference limiter's chunk boundary.
        // Its streaming API adds chunk-1 frames; the final one-frame wet delay
        // below completes the exact AU latency without shifting the work window.
        stageDelay_ = delay_ - limiter_.chunkFrames();
        capacity_ = delay_ + window_ + 1;
        for (auto& b : raw_) b.assign(capacity_, 0);
        for (auto& b : boosted_) b.assign(capacity_, 0);
        hamming_.resize(window_);
        for (uint32_t i = 0; i < window_; ++i)
            hamming_[i] = float(.53836 - .46164 * std::cos(6.283185307179586 * i / (window_ - 1)));
        meterHop_ = std::max(1u, uint32_t(rate_ * .01));
        reset();
    }
    void reset() noexcept {
        for (auto& b : raw_) std::fill(b.begin(), b.end(), 0);
        for (auto& b : boosted_) std::fill(b.begin(), b.end(), 0);
        for (auto& w : windows_) w = Window{};
        limiter_.reset();
        sequence_ = 0; mask_ = 0; meterCount_ = 0;
        meterInput_ = meterOutput_ = 0;
        meters_ = {-120, -120, 0, 0};
        for (auto& stream : waveform_) stream.fill(0);
        waveformPosition_ = 0; waveformInputPeak_ = waveformOutputPeak_ = 0;
        mix_ = bypass_ ? 1.f : 0.f;
        lastOutputHop_ = UINT64_MAX;
        wetAlignmentDelay_.fill(0);
        updateConstants();
    }
    void setParameter(uint32_t id, float value) noexcept {
        if (id >= 7) return;
        values_[id] = sanitize(id, value);
        mask_ &= ~(1u << id);
        updateConstants();
    }
    void rampParameter(uint32_t id, float value, uint32_t frames) noexcept {
        if (id >= 7) return;
        value = sanitize(id, value);
        if (!frames) { setParameter(id, value); return; }
        ramps_[id] = {value, (value - values_[id]) / frames, frames};
        mask_ |= 1u << id;
    }
    float parameter(uint32_t i) const noexcept { return i < 7 ? values_[i] : 0; }
    void setBypass(bool value) noexcept { bypass_ = value; }
    uint32_t latencyFrames() const noexcept { return delay_; }
    double latencySeconds() const noexcept { return delay_ / rate_; }
    float meter(uint32_t i) const noexcept { return i < 4 ? meters_[i] : 0; }
    float waveform(uint32_t stream, uint32_t index) const noexcept {
        return stream < 2 && index < 256 ? waveform_[stream][(waveformPosition_ + index) % 256] : 0.f;
    }

    void process(float* const* input, float* const* output, uint32_t channels, uint32_t frames) noexcept {
        if (channels < 1 || channels > 2 || !capacity_) return;
        for (uint32_t offset = 0; offset < frames;) {
            const uint32_t count = std::min(quantum, frames - offset);
            std::array<std::array<float, quantum>, 2> wet{}, dry{}, delayed{};
            std::array<float, quantum> strengths{}, mixes{}, ceilings{}, outputs{};
            for (uint32_t i = 0; i < count; ++i) {
                if (mask_) advanceRamps();
                // Constant computation is bounded to 1 kHz during automation.
                if (mask_ && sequence_ % std::max(1u, uint32_t(rate_ * .001)) == 0) updateConstants();
                const uint32_t write = uint32_t(sequence_ % capacity_);
                float linked = 0;
                for (uint32_t c = 0; c < channels; ++c) {
                    float v = input[c][offset + i];
                    v = std::isfinite(v) ? std::clamp(v, -64.f, 64.f) : 0;
                    if (std::abs(v) < 1.e-20f) v = 0;
                    raw_[c][write] = v;
                    boosted_[c][write] = v * inputGain_;
                    linked = std::max(linked, std::abs(boosted_[c][write]));
                }
                if (sequence_ % half_ == 0) {
                    auto& w = windows_[(sequence_ / half_) % windows_.size()];
                    w = Window{}; w.start = sequence_; w.active = true;
                }
                // Two overlapping detectors: no whole-window audio scan or allocation.
                for (auto& w : windows_) if (w.active && sequence_ >= w.start && sequence_ - w.start < window_) {
                    if (w.count < bins_) {
                        w.sum += linked * linked;
                        if (++w.inBin == frame_) {
                            w.energy[w.count++] = float(double(w.sum / frame_) + 1.e-8);
                            w.sum = 0; w.inBin = 0;
                        }
                    }
                    if (sequence_ - w.start + 1 == window_) { computeGains(w); w.active = false; w.ready = true; }
                }
                const bool hasStage = sequence_ >= stageDelay_;
                const uint64_t source = hasStage ? sequence_ - stageDelay_ : 0;
                if (hasStage) {
                    const uint64_t hop = source / half_;
                    if (hop != lastOutputHop_) {
                        lastOutputHop_ = hop;
                        for (uint32_t c = 0; c < channels; ++c) {
                            overlap_[c] = hop > 0 && (sample(boosted_[c], hop * half_) != 0 ||
                                sample(boosted_[c], hop * half_ + 10) != 0 || sample(boosted_[c], hop * half_ + half_ / 2) != 0);
                        }
                    }
                    const uint32_t p = uint32_t(source % half_);
                    const Window& current = windows_[hop % windows_.size()];
                    const Window& previous = windows_[(hop + windows_.size() - 1) % windows_.size()];
                    for (uint32_t c = 0; c < channels; ++c) {
                        const float value = sample(boosted_[c], source);
                        const float currentValue = value * gainAt(current, p);
                        wet[c][i] = overlap_[c]
                            ? (value * gainAt(previous, p + half_)) * hamming_[p + half_] + currentValue * hamming_[p]
                            : currentValue;
                    }
                }
                for (uint32_t c = 0; c < channels; ++c)
                    dry[c][i] = sequence_ >= delay_ ? sample(raw_[c], sequence_ - delay_) : 0;
                const float targetMix = bypass_ ? 1.f : 0.f;
                const float step = float(1.0 / (.005 * rate_));
                mix_ += std::clamp(targetMix - mix_, -step, step);
                mixes[i] = mix_; strengths[i] = strength_; ceilings[i] = ceiling_; outputs[i] = outputGain_;
                ++sequence_;
            }
            float* ins[2] = {wet[0].data(), wet[1].data()};
            float* outs[2] = {delayed[0].data(), delayed[1].data()};
            limiter_.process(ins, outs, channels, count, values_[0]);
            for (uint32_t i = 0; i < count; ++i) {
                float peak = 0, inputPeak = 0;
                std::array<float, 2> result{};
                for (uint32_t c = 0; c < channels; ++c) {
                    inputPeak = std::max(inputPeak, std::abs(dry[c][i]));
                    const float alignedWet = wetAlignmentDelay_[c];
                    wetAlignmentDelay_[c] = delayed[c][i];
                    const float wetPart = alignedWet * strengths[i];
                    const float leveled = float(double(wetPart) + double(dry[c][i]) * (1.0 - double(strengths[i])));
                    const float processed = leveled * outputs[i];
                    result[c] = mixes[i] >= 1.f ? dry[c][i] : processed + mixes[i] * (dry[c][i] - processed);
                    peak = std::max(peak, std::abs(result[c]));
                }
                // 0 dB means original limiter only; a negative setting opts into
                // the additional sample-peak guard, absent from the reference.
                const float guard = ceilings[i] < 1.f && peak > ceilings[i] && mixes[i] < 1.f ? ceilings[i] / peak : 1.f;
                for (uint32_t c = 0; c < channels; ++c) output[c][offset + i] = result[c] * guard;
                meterInput_ += double(inputPeak) * inputPeak;
                meterOutput_ += double(peak * guard) * (peak * guard);
                waveformInputPeak_ = std::max(waveformInputPeak_, inputPeak);
                waveformOutputPeak_ = std::max(waveformOutputPeak_, peak * guard);
                if (++meterCount_ == meterHop_) {
                    meters_[0] = powerDb(meterInput_ / meterHop_);
                    meters_[1] = powerDb(meterOutput_ / meterHop_);
                    meters_[2] = std::clamp(meters_[1] - meters_[0], -60.f, 60.f);
                    meters_[3] = powerDb(double(guard) * guard);
                    waveform_[0][waveformPosition_] = std::min(1.f, waveformInputPeak_);
                    waveform_[1][waveformPosition_] = std::min(1.f, waveformOutputPeak_);
                    waveformPosition_ = (waveformPosition_ + 1) % 256;
                    waveformInputPeak_ = waveformOutputPeak_ = 0;
                    meterInput_ = meterOutput_ = 0; meterCount_ = 0;
                }
            }
            offset += count;
        }
    }

private:
    static constexpr uint32_t maxBins = 128, quantum = 256;
    struct Ramp { float target = 0, step = 0; uint32_t remaining = 0; };
    struct Window {
        uint64_t start = 0;
        bool active = false, ready = false;
        uint32_t count = 0, inBin = 0;
        float sum = 0;
        std::array<float, maxBins> energy{}, gain{};
    };
    struct Info { float rms = 0, db = 0, energy = 0, prefix = 0; uint32_t active = 0; };
    static float powerDb(double v) noexcept { return float(10 * std::log10(std::max(v, 1.e-12))); }
    float sample(const std::vector<float>& b, uint64_t time) const noexcept { return b[time % capacity_]; }
    void updateConstants() noexcept {
        const double strength = double(values_[1] / 100.f);
        strength_ = float(std::min(1.0, strength / .8));
        const float drivenDB = float((strength - .8) / .2 * 24);
        const float normalizedDrive = drivenDB / 20.f;
        inputGain_ = strength > .8 ? float(std::pow(10.0, double(normalizedDrive))) : 1.f;
        outputGain_ = float(std::pow(10.0, values_[5] / 20.0));
        ceiling_ = float(std::pow(10.0, values_[6] / 20.0));
    }
    void advanceRamps() noexcept {
        for (uint32_t i = 0; i < 7; ++i) if (mask_ & (1u << i)) {
            auto& r = ramps_[i]; values_[i] += r.step;
            if (--r.remaining == 0) { values_[i] = r.target; mask_ &= ~(1u << i); updateConstants(); }
        }
    }
    void computeGains(Window& window) noexcept {
        const uint32_t n = window.count;
        if (n < 3) { window.gain.fill(1); return; }
        std::array<Info, maxBins> info{}, original{};
        std::array<float, maxBins> transformed{}, gain{};
        float total = 0; uint32_t active = 0;
        for (uint32_t i = 0; i < n; ++i) {
            float rms = std::sqrt(window.energy[i]), db = 20.f * std::log10(rms);
            if (db > values_[4]) { total += window.energy[i]; ++active; }
            info[i] = {rms, db, window.energy[i], total, active};
        }
        original = info;
        const uint32_t minimum = std::clamp(uint32_t(rate_ * values_[3] * .001 / frame_), 1u, n - 1);
        for (uint32_t pass = 0; pass < 2; ++pass) {
            std::array<std::array<uint32_t, 2>, maxBins> pieces{};
            uint32_t pieceCount = 1; pieces[0] = {0, std::min(minimum, n - 1)};
            while (pieces[pieceCount - 1][1] + 1 < n - 1) {
                auto& piece = pieces[pieceCount - 1];
                const uint32_t next = piece[1] + 1;
                const float prefix = piece[0] ? info[piece[0] - 1].prefix : 0;
                const uint32_t num = info[piece[1]].active - (piece[0] ? info[piece[0] - 1].active : 0);
                const float rms = num ? 20.f * std::log10(std::sqrt((info[piece[1]].prefix - prefix) / float(num))) : -120.f;
                if (info[next].db >= values_[4] && (!std::isfinite(rms) || std::abs(rms - info[next].db) >= 10.f)) {
                    pieces[pieceCount++] = {next, std::min(next + minimum, n - 1)};
                } else piece[1] = next;
            }
            // Preserve the original n-2 stopping boundary and -100 dB sentinel
            // for any untouched terminal RMS bin (0x5134 and 0x5298).
            transformed.fill(-100.f);
            for (uint32_t p = 0; p < pieceCount; ++p) {
                const uint32_t first = pieces[p][0], last = pieces[p][1];
                float maxDb = -10000.f; uint32_t audible = 0;
                for (uint32_t i = first; i <= last; ++i) { maxDb = std::max(maxDb, info[i].db); audible += info[i].db > -40.f; }
                const float silent = 1.f - float(audible) / (last - first + 1);
                const bool normalize = audible >= 3 && double(silent) <= .95;
                const float target = -10.f - 2.f * silent;
                for (uint32_t i = first; i <= last; ++i)
                    transformed[i] = normalize ? (info[i].db - maxDb) + target : original[i].db;
            }
            total = 0; active = 0;
            for (uint32_t i = 0; i < n; ++i) {
                const float rms = float(std::pow(10.0, transformed[i] / 20.0));
                const float energy = rms * rms;
                if (transformed[i] > values_[4]) { total += energy; ++active; }
                info[i] = {rms, transformed[i], energy, total, active};
            }
        }
        const float maxGain = std::abs(values_[2] - defaults[2]) < 1.e-4f ? 17.f : float(std::pow(10.0, values_[2] / 20.0));
        for (uint32_t i = 0; i < n; ++i) gain[i] = std::min(maxGain, info[i].db < -92 ? 1.f : info[i].rms / original[i].rms);
        for (uint32_t i = 0; i + 1 < n; ++i) gain[i] = std::min(gain[i], gain[i + 1]);
        gain[n] = 0;
        constexpr float weights[8] = {.1183f, .1239f, .1279f, .1299f, .1299f, .1279f, .1239f, .1183f};
        window.gain.fill(0);
        for (uint32_t i = 0; i <= n; ++i) for (int j = 0; j < 8; ++j) {
            const int index = int(i) + 4 - j;
            if (index >= 0 && index <= int(n)) window.gain[i] += weights[j] * gain[index];
        }
    }
    float gainAt(const Window& w, uint32_t position) const noexcept {
        if (!w.ready) return 1.f;
        const uint32_t index = position / frame_;
        if (index >= w.count) return 1.f;
        const double step = (double(w.gain[index + 1]) - double(w.gain[index])) / (frame_ - 1);
        return float(step * double(position % frame_) + double(w.gain[index]));
    }
    // ReferenceLimiter keeps its namespace local to this project.
    ReferenceLimiter limiter_;
    std::array<float, 7> values_ = defaults;
    std::array<Ramp, 7> ramps_{};
    std::array<Window, 6> windows_{};
    std::array<std::vector<float>, 2> raw_, boosted_;
    std::vector<float> hamming_;
    std::array<bool, 2> overlap_{};
    std::array<float, 2> wetAlignmentDelay_{};
    std::array<float, 4> meters_ = {-120, -120, 0, 0};
    std::array<std::array<float, 256>, 2> waveform_{};
    uint32_t waveformPosition_ = 0;
    float waveformInputPeak_ = 0, waveformOutputPeak_ = 0;
    double rate_ = 48000, meterInput_ = 0, meterOutput_ = 0;
    uint64_t sequence_ = 0, lastOutputHop_ = UINT64_MAX;
    uint32_t window_ = 0, half_ = 0, delay_ = 0, stageDelay_ = 0, capacity_ = 0, frame_ = 2400, bins_ = 100;
    uint32_t mask_ = 0, meterHop_ = 480, meterCount_ = 0;
    float strength_ = 1, inputGain_ = 1, outputGain_ = 1, ceiling_ = 1, mix_ = 0;
    bool bypass_ = false;
};
}

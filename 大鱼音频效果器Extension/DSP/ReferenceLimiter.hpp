#pragma once

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace dayu {

// Mathematical reconstruction of the active ARM64 LookaheadLimiter + its
// Levelmatic::limiter wrapper, from the installed Levelmatic 1.0.8 binary.
// This is new source, not original source. See Analysis/Levelmatic/performance-notes.md.
// prepare()/reset() run outside rendering. Processing never allocates or waits.
// The original .2s delay, two box filters, cached peak/countdown semantics and
// wrapper's processed-tail reuse are preserved. Trial watermark is not included.
class ReferenceLimiter final {
public:
    void prepare(double sampleRate, std::uint32_t channels, std::uint32_t maxFrames) {
        sampleRate_ = std::isfinite(sampleRate) && sampleRate >= 8000.0
            ? std::min(sampleRate, 384000.0) : 48000.0;
        channels_ = std::clamp<std::uint32_t>(channels, 1, 2);
        chunkFrames_ = std::max<std::uint32_t>(2048, maxFrames);
        const auto integerRate = static_cast<std::uint32_t>(sampleRate_);
        const auto window50 = static_cast<std::uint32_t>(double(integerRate) * 0.05);
        const float sampleRateFloat = static_cast<float>(integerRate);
        delayFrames_ = static_cast<std::uint32_t>(sampleRateFloat * 0.2f);
        halfWindow_ = delayFrames_ / 2;
        const auto wrapperPadding = static_cast<std::uint32_t>(
            sampleRateFloat * 0.2f + static_cast<float>(8 * window50));
        extractOffset_ = (wrapperPadding - 4 * window50) / 2;
        workFrames_ = chunkFrames_ + wrapperPadding;
        // Original: exp(-1 / double((float(fs) * releaseParam) * .5f)),
        // releaseParam=.2; recomputing this at each sample changes no state.
        releaseCoefficient_ = static_cast<float>(std::exp(
            -1.0 / double((sampleRateFloat * 0.2f) * 0.5f)));
        peaks_.resize(workFrames_);
        queuePeaks_.resize(delayFrames_ + 1);
        queueTimes_.resize(delayFrames_ + 1);
        smoothing1_.resize(halfWindow_);
        smoothing2_.resize(halfWindow_);
        for (std::uint32_t c = 0; c < 2; ++c) {
            workAudio_[c].resize(workFrames_);
            audioDelay_[c].resize(delayFrames_);
            streamedInput_[c].resize(chunkFrames_);
            streamedOutput_[c].resize(chunkFrames_);
        }
        prepared_ = true;
        reset();
    }

    void reset() noexcept {
        for (auto &v : workAudio_) std::fill(v.begin(), v.end(), 0.f);
        for (auto &v : audioDelay_) std::fill(v.begin(), v.end(), 0.f);
        for (auto &v : streamedInput_) std::fill(v.begin(), v.end(), 0.f);
        for (auto &v : streamedOutput_) std::fill(v.begin(), v.end(), 0.f);
        std::fill(peaks_.begin(), peaks_.end(), 0.f);
        std::fill(smoothing1_.begin(), smoothing1_.end(), 0.f);
        std::fill(smoothing2_.begin(), smoothing2_.end(), 0.f);
        delayPosition_ = smoothingPosition_ = queueHead_ = queueTail_ = 0;
        sampleClock_ = 0;
        peakCountdown_ = 0;
        cachedPeak_ = sum1_ = sum2_ = reduction_ = 0.f;
        streamFill_ = streamRead_ = streamAvailable_ = 0;
    }

    std::uint32_t chunkFrames() const noexcept { return chunkFrames_; }
    std::uint32_t streamingLatencyFrames() const noexcept { return chunkFrames_ - 1; }
    std::uint32_t mathematicalDelayFrames() const noexcept { return delayFrames_; }
    std::uint32_t wrapperExtractOffsetFrames() const noexcept { return extractOffset_; }
    float gainReduction() const noexcept { return 1.f - reduction_; }

    // For an OLA scheduler that already owns complete chunks. Exactly chunkFrames()
    // input samples per channel. No stream accumulation latency is introduced.
    // Do not mix this API with process() on the same instance without reset().
    void processReadyChunk(float *const *input, float *const *output,
                           std::uint32_t channels, float targetDB) noexcept {
        if (!prepared_ || !input || !output || (channels == 0 || channels > channels_)) return;
        for (std::uint32_t c = 0; c < channels; ++c) {
            std::copy_n(input[c], chunkFrames_, workAudio_[c].data());
        }
        processWorkWindow(targetDB, channels);
        for (std::uint32_t c = 0; c < channels; ++c) {
            std::copy_n(workAudio_[c].data() + extractOffset_, chunkFrames_, output[c]);
        }
    }

    // Arbitrary host frame counts, mono/stereo planar float, in-place safe.
    // Initial accumulation adds chunkFrames()-1 samples of latency. A containing
    // AU must report/compensate that if it uses this streaming entry point.
    void process(float *const *input, float *const *output, std::uint32_t channels,
                 std::uint32_t frames, float targetDB) noexcept {
        if (!prepared_ || !input || !output || (channels == 0 || channels > channels_)) return;
        for (std::uint32_t i = 0; i < frames; ++i) {
            for (std::uint32_t c = 0; c < channels; ++c) {
                streamedInput_[c][streamFill_] = input[c][i];
            }
            if (++streamFill_ == chunkFrames_) {
                std::array<float *, 2> in{}, out{};
                for (std::uint32_t c = 0; c < channels; ++c) {
                    in[c] = streamedInput_[c].data();
                    out[c] = streamedOutput_[c].data();
                }
                processReadyChunk(in.data(), out.data(), channels, targetDB);
                streamFill_ = streamRead_ = 0;
                streamAvailable_ = chunkFrames_;
            }
            for (std::uint32_t c = 0; c < channels; ++c) {
                output[c][i] = streamAvailable_ ? streamedOutput_[c][streamRead_] : 0.f;
            }
            if (streamAvailable_) { ++streamRead_; --streamAvailable_; }
        }
    }

private:
    std::uint32_t queueNext(std::uint32_t p) const noexcept {
        return p + 1 == queuePeaks_.size() ? 0 : p + 1;
    }
    std::uint32_t queuePrevious(std::uint32_t p) const noexcept {
        return p ? p - 1 : static_cast<std::uint32_t>(queuePeaks_.size() - 1);
    }
    float pushPeak(float peak) noexcept {
        while (queueHead_ != queueTail_ &&
               queueTimes_[queueHead_] + delayFrames_ <= sampleClock_) {
            queueHead_ = queueNext(queueHead_);
        }
        while (queueHead_ != queueTail_) {
            const auto last = queuePrevious(queueTail_);
            if (queuePeaks_[last] > peak) break;
            queueTail_ = last;
        }
        queuePeaks_[queueTail_] = peak;
        queueTimes_[queueTail_] = sampleClock_++;
        queueTail_ = queueNext(queueTail_);
        return queuePeaks_[queueHead_];
    }
    void processWorkWindow(float targetDB, std::uint32_t channels) noexcept {
        std::fill(peaks_.begin(), peaks_.end(), 0.f);
        for (std::uint32_t c = 0; c < channels; ++c) {
            for (std::uint32_t i = 0; i < workFrames_; ++i) {
                peaks_[i] = std::max(peaks_[i], std::abs(workAudio_[c][i]));
            }
        }
        const float outputGain = static_cast<float>(std::pow(
            10.0, (double(targetDB) + 1.6) / 20.0));
        for (std::uint32_t i = 0; i < workFrames_; ++i) {
            const float currentPeak = peaks_[i];
            const float trueWindowPeak = pushPeak(currentPeak);
            // Preserve original N+1 countdown behavior. Using the queue front on
            // every sample would drop held peaks one sample earlier in some cases.
            if (--peakCountdown_ < 0 || currentPeak > cachedPeak_) {
                cachedPeak_ = trueWindowPeak;
                peakCountdown_ = static_cast<std::int32_t>(delayFrames_);
            }
            const float drivenPeak = cachedPeak_ * 1.2f;
            float scaledReduction = drivenPeak > 1.f ? 1.f - 1.f / drivenPeak : 0.f;
            scaledReduction /= static_cast<float>(halfWindow_);
            sum1_ = (sum1_ + scaledReduction) - smoothing1_[smoothingPosition_];
            smoothing1_[smoothingPosition_] = scaledReduction;
            const float stage2Input = sum1_ / static_cast<float>(halfWindow_);
            sum2_ = (sum2_ + stage2Input) - smoothing2_[smoothingPosition_];
            smoothing2_[smoothingPosition_] = stage2Input;
            reduction_ = std::max(sum2_, std::max(reduction_ * releaseCoefficient_, 0.f));
            const float gain = 1.f - reduction_;
            for (std::uint32_t c = 0; c < channels; ++c) {
                const float delayed = audioDelay_[c][delayPosition_];
                audioDelay_[c][delayPosition_] = workAudio_[c][i];
                workAudio_[c][i] = (delayed * gain) * outputGain;
            }
            if (++delayPosition_ == delayFrames_) delayPosition_ = 0;
            if (++smoothingPosition_ == halfWindow_) smoothingPosition_ = 0;
        }
    }

    double sampleRate_ = 48000;
    std::uint32_t channels_ = 2, chunkFrames_ = 2048, delayFrames_ = 9600;
    std::uint32_t halfWindow_ = 4800, extractOffset_ = 9600, workFrames_ = 30848;
    std::array<std::vector<float>, 2> workAudio_, audioDelay_, streamedInput_, streamedOutput_;
    std::vector<float> peaks_, queuePeaks_, smoothing1_, smoothing2_;
    std::vector<std::uint64_t> queueTimes_;
    std::uint32_t delayPosition_ = 0, smoothingPosition_ = 0;
    std::uint32_t queueHead_ = 0, queueTail_ = 0;
    std::uint64_t sampleClock_ = 0;
    std::int32_t peakCountdown_ = 0;
    float cachedPeak_ = 0, sum1_ = 0, sum2_ = 0, reduction_ = 0;
    float releaseCoefficient_ = 0.f;
    std::uint32_t streamFill_ = 0, streamRead_ = 0, streamAvailable_ = 0;
    bool prepared_ = false;
};

} // namespace dayu

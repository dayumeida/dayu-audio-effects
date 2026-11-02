#import "_______ExtensionAUProcessHelper.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>
#include "_______ExtensionDSPKernel.hpp"

// Stable native heap storage; the render block captures this implementation directly.
class ProcessHelperImpl {
public:
    static ProcessHelperImpl *createForSubtype(uint32_t subtype) {
        if (!dayu::isSupportedEffect(subtype)) return nullptr;
        return new ProcessHelperImpl(static_cast<dayu::EffectKind>(subtype));
    }
    bool allocate(double sampleRate, uint32_t channels, uint32_t frames) {
        if (channels < 1 || channels > 2 || frames < 1 || frames > 16384 || !mKernel.supportsRate(sampleRate) || !mKernel.resourcesReady()) return false;
        try {
            mInput.assign(size_t(channels) * frames, 0.f);
            mOutput.assign(size_t(channels) * frames, 0.f);
            mKernel.initialize(sampleRate);
        } catch (...) { mCapacity = 0; return false; }
        mChannels = channels;
        mCapacity = frames;
        mKernel.setMaximumFramesToRender(frames);
        reset();
        return true;
    }
    void deallocate() {
        mKernel.deInitialize();
        std::vector<float>().swap(mInput);
        std::vector<float>().swap(mOutput);
        mCapacity = 0;
        mExpectedSampleTime = std::numeric_limits<double>::quiet_NaN();
    }
    void reset() { mKernel.reset(); mExpectedSampleTime = std::numeric_limits<double>::quiet_NaN(); }
    bool configureResources(const char* modelPath) { try { return mKernel.configureResources(modelPath); } catch (...) { return false; } }
    uint32_t effectSubtype() const { return mKernel.effectSubtype(); }
    uint32_t parameterCount() const { return mKernel.parameterCount(); }
    float defaultParameter(uint32_t address) const { return mKernel.defaultParameter(address); }
    void setParameter(AUParameterAddress address, AUValue value) { mKernel.setParameter(address, value); }
    AUValue getParameter(AUParameterAddress address) const { return mKernel.getParameter(address); }
    void setBypass(bool value) { mKernel.setBypass(value); }
    bool isBypassed() const { return mKernel.isBypassed(); }
    AUAudioFrameCount maximumFramesToRender() const { return mKernel.maximumFramesToRender(); }
    void setMaximumFramesToRender(AUAudioFrameCount frames) { mKernel.setMaximumFramesToRender(frames); }
    double latencySeconds() const { return mKernel.latencySeconds(); }
    double latencySecondsForRate(double rate) const { return mKernel.latencySecondsForRate(rate); }
    bool hasReceivedAudio() const { return mKernel.hasReceivedAudio(); }
    double warmupRemainingSeconds() const { return mKernel.warmupRemainingSeconds(); }
    double tailSeconds() const { return mKernel.tailSeconds(); }
    float getMeter(uint32_t index) const { return mKernel.getMeter(index); }
    float getWaveformPoint(uint32_t stream, uint32_t index) const { return mKernel.getWaveformPoint(stream, index); }

    AUInternalRenderBlock internalRenderBlock() {
        return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,
                                  const AudioTimeStamp *timestamp,
                                  AUAudioFrameCount frameCount,
                                  NSInteger outputBusNumber,
                                  AudioBufferList *outputData,
                                  const AURenderEvent *events,
                                  AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
            return render(flags, timestamp, frameCount, outputBusNumber, outputData, events, pullInputBlock);
        };
    }

private:
    explicit ProcessHelperImpl(dayu::EffectKind kind) : mKernel(kind) {}
    struct StereoBufferList { UInt32 mNumberBuffers; AudioBuffer mBuffers[2]; };
    _______ExtensionDSPKernel mKernel;
    std::vector<float> mInput, mOutput;
    uint32_t mChannels = 2, mCapacity = 0;
    double mExpectedSampleTime = std::numeric_limits<double>::quiet_NaN();

    AUAudioUnitStatus render(AudioUnitRenderActionFlags *flags, const AudioTimeStamp *timestamp,
                             AUAudioFrameCount frames, NSInteger bus, AudioBufferList *output,
                             const AURenderEvent *events, AURenderPullInputBlock __unsafe_unretained pull) {
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        if (!timestamp) return kAudioUnitErr_InvalidPropertyValue;
        if (frames > mCapacity || frames > mKernel.maximumFramesToRender()) return kAudioUnitErr_TooManyFramesToProcess;
        if (!output || output->mNumberBuffers != mChannels) return kAudioUnitErr_FormatNotSupported;
        if (!pull) return kAudioUnitErr_NoConnection;
        if (frames == 0) return noErr;
        for (uint32_t c = 0; c < mChannels; ++c) {
            if (output->mBuffers[c].mNumberChannels != 1 ||
                (output->mBuffers[c].mData && output->mBuffers[c].mDataByteSize < frames * sizeof(float)))
                return kAudioUnitErr_FormatNotSupported;
        }
        const bool hasSampleTime = (timestamp->mFlags & kAudioTimeStampSampleTimeValid) && std::isfinite(timestamp->mSampleTime);
        const double start = hasSampleTime ? timestamp->mSampleTime : (std::isfinite(mExpectedSampleTime) ? mExpectedSampleTime : 0);
        if (hasSampleTime && std::isfinite(mExpectedSampleTime) && std::abs(start - mExpectedSampleTime) > 0.5) mKernel.reset();
        mExpectedSampleTime = start + frames;
        StereoBufferList input{};
        input.mNumberBuffers = mChannels;
        for (uint32_t c = 0; c < mChannels; ++c) {
            input.mBuffers[c] = AudioBuffer{1, UInt32(frames * sizeof(float)), mInput.data() + c * mCapacity};
        }
        AudioUnitRenderActionFlags inputFlags = flags ? *flags : 0;
        inputFlags &= ~kAudioUnitRenderAction_OutputIsSilence;
        const auto status = pull(&inputFlags, timestamp, frames, 0, reinterpret_cast<AudioBufferList *>(&input));
        if (status != noErr) return status;
        if (input.mNumberBuffers != mChannels) return kAudioUnitErr_FormatNotSupported;
        for (uint32_t c = 0; c < mChannels; ++c) {
            if (input.mBuffers[c].mNumberChannels != 1 || !input.mBuffers[c].mData ||
                input.mBuffers[c].mDataByteSize < frames * sizeof(float)) return kAudioUnitErr_FormatNotSupported;
            if (inputFlags & kAudioUnitRenderAction_OutputIsSilence) std::memset(input.mBuffers[c].mData, 0, frames * sizeof(float));
        }
        uint32_t offset = 0;
        auto event = events;
        const auto now = AUEventSampleTime(start);
        while (offset < frames) {
            // Hosts may include late, immediate, or future events. Bound every segment.
            while (event && (event->head.eventSampleTime == AUEventSampleTimeImmediate || event->head.eventSampleTime <= now + offset)) {
                mKernel.handleOneEvent(now + offset, event);
                event = event->head.next;
            }
            uint32_t count = frames - offset;
            if (event && event->head.eventSampleTime < now + frames)
                count = uint32_t(std::max<AUEventSampleTime>(0, event->head.eventSampleTime - now - offset));
            if (count == 0) continue;
            float *ins[2]{}, *outs[2]{};
            for (uint32_t c = 0; c < mChannels; ++c) {
                ins[c] = static_cast<float *>(input.mBuffers[c].mData) + offset;
                outs[c] = mOutput.data() + c * mCapacity + offset;
            }
            mKernel.process(ins, outs, mChannels, count);
            offset += count;
        }
        for (uint32_t c = 0; c < mChannels; ++c) {
            if (!output->mBuffers[c].mData) output->mBuffers[c].mData = mOutput.data() + c * mCapacity;
            else std::memcpy(output->mBuffers[c].mData, mOutput.data() + c * mCapacity, frames * sizeof(float));
            output->mBuffers[c].mDataByteSize = UInt32(frames * sizeof(float));
        }
        if (flags) *flags &= ~kAudioUnitRenderAction_OutputIsSilence;
        return noErr;
    }
};

AUProcessHelper::AUProcessHelper(uint32_t subtype) : impl_(ProcessHelperImpl::createForSubtype(subtype)) {}
AUProcessHelper::~AUProcessHelper() { delete impl_; }
AUProcessHelper* AUProcessHelper::createForSubtype(uint32_t subtype) {
    if (!dayu::isSupportedEffect(subtype)) return nullptr;
    return new AUProcessHelper(subtype);
}
AUProcessHelper* AUProcessHelper::create() { return createForSubtype(uint32_t(dayu::EffectKind::referenceLeveler)); }
AUProcessHelper* AUProcessHelper::createLowLatency() { return createForSubtype(uint32_t(dayu::EffectKind::realtimeLeveler)); }
void AUProcessHelper::destroy(AUProcessHelper* helper) { delete helper; }
bool AUProcessHelper::allocate(double rate, uint32_t channels, uint32_t frames) { return impl_->allocate(rate, channels, frames); }
void AUProcessHelper::deallocate() { impl_->deallocate(); }
void AUProcessHelper::reset() { impl_->reset(); }
bool AUProcessHelper::configureResources(const char* path) { return impl_->configureResources(path); }
uint32_t AUProcessHelper::effectSubtype() const { return impl_->effectSubtype(); }
uint32_t AUProcessHelper::parameterCount() const { return impl_->parameterCount(); }
float AUProcessHelper::defaultParameter(uint32_t id) const { return impl_->defaultParameter(id); }
void AUProcessHelper::setParameter(AUParameterAddress id, AUValue value) { impl_->setParameter(id, value); }
AUValue AUProcessHelper::getParameter(AUParameterAddress id) const { return impl_->getParameter(id); }
void AUProcessHelper::setBypass(bool value) { impl_->setBypass(value); }
bool AUProcessHelper::isBypassed() const { return impl_->isBypassed(); }
AUAudioFrameCount AUProcessHelper::maximumFramesToRender() const { return impl_->maximumFramesToRender(); }
void AUProcessHelper::setMaximumFramesToRender(AUAudioFrameCount frames) { impl_->setMaximumFramesToRender(frames); }
double AUProcessHelper::latencySeconds() const { return impl_->latencySeconds(); }
double AUProcessHelper::latencySecondsForRate(double rate) const { return impl_->latencySecondsForRate(rate); }
bool AUProcessHelper::hasReceivedAudio() const { return impl_->hasReceivedAudio(); }
double AUProcessHelper::warmupRemainingSeconds() const { return impl_->warmupRemainingSeconds(); }
double AUProcessHelper::tailSeconds() const { return impl_->tailSeconds(); }
float AUProcessHelper::getMeter(uint32_t id) const { return impl_->getMeter(id); }
float AUProcessHelper::getWaveformPoint(uint32_t s, uint32_t i) const { return impl_->getWaveformPoint(s, i); }
AUInternalRenderBlock AUProcessHelper::internalRenderBlock() { return impl_->internalRenderBlock(); }

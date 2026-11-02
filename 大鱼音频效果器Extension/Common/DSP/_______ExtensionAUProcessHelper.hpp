#pragma once
#import <AudioToolbox/AudioToolbox.h>
#include <cstdint>

class ProcessHelperImpl;
// The implementation stays in native C++ so Swift never instantiates model/FFT
// templates or their global caches. The audio render block captures stable storage.
class __attribute__((swift_attr("import_reference")))
      __attribute__((swift_attr("retain:immortal")))
      __attribute__((swift_attr("release:immortal")))
      __attribute__((swift_attr("unsafe"))) AUProcessHelper {
public:
    static AUProcessHelper* createForSubtype(uint32_t subtype);
    static AUProcessHelper* create();
    static AUProcessHelper* createLowLatency();
    static void destroy(AUProcessHelper* helper);
    bool allocate(double sampleRate, uint32_t channels, uint32_t frames);
    void deallocate();
    void reset();
    bool configureResources(const char* modelPath);
    uint32_t effectSubtype() const;
    uint32_t parameterCount() const;
    float defaultParameter(uint32_t address) const;
    void setParameter(AUParameterAddress address, AUValue value);
    AUValue getParameter(AUParameterAddress address) const;
    void setBypass(bool value);
    bool isBypassed() const;
    AUAudioFrameCount maximumFramesToRender() const;
    void setMaximumFramesToRender(AUAudioFrameCount frames);
    double latencySeconds() const;
    double latencySecondsForRate(double rate) const;
    bool hasReceivedAudio() const;
    double warmupRemainingSeconds() const;
    double tailSeconds() const;
    float getMeter(uint32_t index) const;
    float getWaveformPoint(uint32_t stream, uint32_t index) const;
    AUInternalRenderBlock internalRenderBlock();
private:
    explicit AUProcessHelper(uint32_t subtype);
    ~AUProcessHelper();
    AUProcessHelper(const AUProcessHelper&) = delete;
    AUProcessHelper& operator=(const AUProcessHelper&) = delete;
    ProcessHelperImpl* impl_;
};

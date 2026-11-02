#pragma once
#include <cstdint>

namespace dayu {
enum class EffectKind : uint32_t {
    referenceLeveler = 0x64796c76, // dylv: published component, do not repurpose
    realtimeLeveler = 0x64796c6c,  // dyll
    audioDenoise = 0x6479646e,     // dydn
    era5Declipper = 0x64796372     // dycr
};
inline bool isSupportedEffect(uint32_t subtype) noexcept {
    switch (static_cast<EffectKind>(subtype)) {
        case EffectKind::referenceLeveler:
        case EffectKind::realtimeLeveler:
        case EffectKind::audioDenoise:
        case EffectKind::era5Declipper: return true;
    }
    return false;
}
}

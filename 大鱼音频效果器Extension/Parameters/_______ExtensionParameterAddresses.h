#pragma once
#include <AudioToolbox/AUParameters.h>

typedef NS_ENUM(AUParameterAddress, _______ExtensionParameterAddress) {
    targetLevel = 0,
    amount = 1,
    maxBoost = 2,
    response = 3,
    noiseFloor = 4,
    outputGain = 5,
    ceiling = 6
};

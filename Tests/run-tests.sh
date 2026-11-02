#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-tests Analysis/Levelmatic
for test in ReferenceLimiterTests LevelerReferenceTests LevelerCoreTests; do
  xcrun clang++ -std=c++20 -ffp-contract=off -O3 -Wall -Wextra "Tests/$test.cpp" -o ".build-tests/$test"
  ".build-tests/$test" > "Analysis/Levelmatic/$test.json"
done
for test in ReferenceLimiterTests LevelerCoreTests; do
  xcrun clang++ -std=c++20 -ffp-contract=off -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer "Tests/$test.cpp" -o ".build-tests/$test-sanitized"
  ".build-tests/$test-sanitized" > "Analysis/Levelmatic/$test-sanitized.json"
done
xcrun clang++ -std=c++20 -O2 -ffp-contract=off -fobjc-arc -fblocks \
  -I '大鱼音频效果器Extension/DSP' -I '大鱼音频效果器Extension/Parameters' \
  Tests/AUProcessHelperTests.mm \
  "大鱼音频效果器Extension/Common/DSP/AUProcessHelper.mm" -framework AudioToolbox -framework AVFoundation -framework Accelerate \
  -o .build-tests/AUProcessHelperTests
.build-tests/AUProcessHelperTests > Analysis/Levelmatic/AUProcessHelperTests.json
# FCP editing path and short, discontinuous waveform-analysis pulls.
xcrun clang++ -std=c++20 -O3 -ffp-contract=off Tests/RealtimeLevelerCoreTests.cpp -o .build-tests/RealtimeLevelerCoreTests
.build-tests/RealtimeLevelerCoreTests > Analysis/Levelmatic/RealtimeLevelerCoreTests.json
xcrun clang++ -std=c++20 -O1 -g -ffp-contract=off -fsanitize=address,undefined -fno-omit-frame-pointer Tests/RealtimeLevelerCoreTests.cpp -o .build-tests/RealtimeLevelerCoreTests-sanitized
.build-tests/RealtimeLevelerCoreTests-sanitized > Analysis/Levelmatic/RealtimeLevelerCoreTests-sanitized.json
xcrun clang++ -std=c++20 -O2 -ffp-contract=off -fobjc-arc -fblocks \
  -I '大鱼音频效果器Extension/DSP' -I '大鱼音频效果器Extension/Parameters' \
  Tests/FCPResponseTests.mm \
  "大鱼音频效果器Extension/Common/DSP/AUProcessHelper.mm" -framework AudioToolbox -framework AVFoundation -framework Accelerate \
  -o .build-tests/FCPResponseTests
.build-tests/FCPResponseTests > Analysis/Levelmatic/FCPResponseTests.json

# Explicit component identity must preserve both existing DSP algorithms.
mkdir -p Analysis/MultiEffect
xcrun clang++ -std=c++20 -O3 -ffp-contract=off -fobjc-arc -fblocks \
  -I '大鱼音频效果器Extension/DSP' -I '大鱼音频效果器Extension/Parameters' \
  Tests/EffectFactoryTests.mm \
  "大鱼音频效果器Extension/Common/DSP/AUProcessHelper.mm" -framework AudioToolbox -framework AVFoundation -framework Accelerate \
  -o .build-tests/EffectFactoryTests
.build-tests/EffectFactoryTests > Analysis/MultiEffect/EffectFactoryTests.json

# Denoiser: fresh render threads, arbitrary blocks, reset, bad samples and malloc-zone instrumentation.
xcrun clang++ -std=c++20 -O3 -ffp-contract=off -I '大鱼音频效果器Extension/DSP' \
  Tests/AudioDenoiseCoreTests.cpp -framework Accelerate -o .build-tests/AudioDenoiseCoreTests
.build-tests/AudioDenoiseCoreTests '大鱼音频效果器Extension/UI/Resources/dayu-denoise-weights.bin' > Analysis/MultiEffect/AudioDenoiseCoreTests.jsonl
xcrun clang++ -std=c++20 -O1 -g -ffp-contract=off -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I '大鱼音频效果器Extension/DSP' Tests/AudioDenoiseCoreTests.cpp -framework Accelerate -o .build-tests/AudioDenoiseCoreTests-sanitized
.build-tests/AudioDenoiseCoreTests-sanitized '大鱼音频效果器Extension/UI/Resources/dayu-denoise-weights.bin' > Analysis/MultiEffect/AudioDenoiseCoreTests-sanitized.jsonl
# Restorer: bounded reconstruction, mono/stereo, automation, reset, stable bypass and sample rates.
xcrun clang++ -std=c++20 -O3 -ffp-contract=off -I '大鱼音频效果器Extension/DSP/Declipper' \
  Tests/DeclipperCoreTests.cpp -framework Accelerate -o .build-tests/DeclipperCoreTests
.build-tests/DeclipperCoreTests > Analysis/MultiEffect/DeclipperCoreTests.json
xcrun clang++ -std=c++20 -O1 -g -ffp-contract=off -fsanitize=address,undefined -fno-omit-frame-pointer \
  -I '大鱼音频效果器Extension/DSP/Declipper' Tests/DeclipperCoreTests.cpp -framework Accelerate -o .build-tests/DeclipperCoreTests-sanitized
.build-tests/DeclipperCoreTests-sanitized brief > Analysis/MultiEffect/DeclipperCoreTests-sanitized.json

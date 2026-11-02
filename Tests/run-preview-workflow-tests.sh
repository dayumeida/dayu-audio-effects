#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build-tests Analysis/OfflineProcessing
preview_sources=(
  Shared/EffectKind.swift
  '大鱼音频效果器/Common/Audio/OfflineAudioProcessor.swift'
  '大鱼音频效果器/Common/Audio/OfflineMediaProcessor.swift'
  '大鱼音频效果器/Common/Audio/MediaPreviewRenderer.swift'
  '大鱼音频效果器/Common/Audio/AudioTimeline.swift'
  '大鱼音频效果器/Model/OfflineProcessingModel.swift'
  '大鱼音频效果器/Model/MediaPreviewModel.swift'
)
for preview_test in PreviewWorkflowTests TimelinePreviewTests; do
  xcrun swiftc -O -target arm64-apple-macos14.0 -parse-as-library -default-isolation MainActor \
    "${preview_sources[@]}" "Tests/$preview_test.swift" -o ".build-tests/$preview_test"
done
.build-tests/PreviewWorkflowTests Analysis/OfflineProcessing/Fixtures Analysis/OfflineProcessing/preview-workflow-report.json
.build-tests/TimelinePreviewTests Analysis/OfflineProcessing/Fixtures Analysis/OfflineProcessing/timeline-preview-report.json

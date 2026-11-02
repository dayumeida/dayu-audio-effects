import AVFoundation
import Foundation

@main struct PreviewWorkflowTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Preview workflow failed: \(error)\n", stderr); exit(1) }
    }

    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition() {
            guard Date() < deadline else { throw OfflineMediaError.message("预览状态等待超时。") }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let audio = root.appendingPathComponent("边界采样.wav")
        let video = root.appendingPathComponent("H264_AAC_错位音轨.mp4")
        let multi = root.appendingPathComponent("双音轨.mp4")
        let long = root.appendingPathComponent("取消测试.wav")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        var checks: [[String: Any]] = []
        let queue = OfflineProcessingModel()
        _ = queue.stage([audio, video, audio])
        precondition(queue.jobs.count == 2 && !queue.isProcessing)
        precondition(queue.jobs.allSatisfy { $0.state == .queued && $0.output == nil })
        checks.append(["test": "import_stages_only_and_deduplicates", "passed": true])

        let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: 0x64796c6c,
            componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
        let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
        let unit = av.auAudioUnit
        let preview = MediaPreviewModel()
        preview.updateSettings(OfflineEffectSettings(kind: .realtimeLeveler, unit: unit))
        preview.load(source: audio)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        let dry = try AVAudioFile(forReading: preview.input!.originalURL)
        let wet = try AVAudioFile(forReading: preview.rendered!.url)
        precondition(dry.length == wet.length && dry.length == 120480)
        precondition(preview.input!.originalWaveform.peaks.count == 512 && preview.rendered!.waveform.peaks.max()! > 0)
        precondition(preview.input!.directory.deletingLastPathComponent() == FileManager.default.temporaryDirectory.standardizedFileURL)
        let originalRenderedURL = preview.rendered!.url
        checks.append(["test": "original_and_processed_waveforms_match_segment_length", "frames": dry.length, "passed": true])

        unit.parameterTree!.allParameters.first(where: { $0.identifier == "outputGain" })!.value = -6
        let changed = OfflineEffectSettings(kind: .realtimeLeveler, unit: unit)
        preview.updateSettings(changed)
        precondition(!preview.isReady && preview.isRendering)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        precondition(preview.rendered!.settings == changed && preview.rendered!.url != originalRenderedURL)
        precondition(!FileManager.default.fileExists(atPath: originalRenderedURL.path))
        checks.append(["test": "parameter_edit_invalidates_old_preview_and_regenerates", "passed": true])

        preview.load(source: long)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        preview.setStart(21.4)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        precondition(abs(preview.input!.start - 21.4) < 1e-6 && preview.input!.frames == 576000)
        precondition(preview.input!.offset == 480000)
        let contextFile = try AVAudioFile(forReading: preview.input!.contextURL)
        precondition(contextFile.length == 1536000)
        checks.append(["test": "long_file_segment_selection_keeps_context_and_12s_preview", "passed": true])

        let staleDirectory = preview.input!.directory
        preview.refresh()
        preview.load(source: video)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        precondition(preview.info!.isVideo && preview.source == video && preview.input!.info.source == video)
        precondition(!FileManager.default.fileExists(atPath: staleDirectory.path))
        checks.append(["test": "source_change_cancels_old_work_and_discards_stale_preview", "passed": true])

        preview.load(source: multi)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        precondition(preview.info!.tracks.count == 2)
        let second = preview.info!.tracks[1]
        preview.selectTrack(second.id)
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        precondition(preview.input!.trackID == second.id && second.sampleRate == 44100)
        checks.append(["test": "video_audio_track_selection_regenerates_at_original_rate", "passed": true])

        for gain in [-3, -9, -4] as [Float] {
            unit.parameterTree!.allParameters.first(where: { $0.identifier == "outputGain" })!.value = gain
            preview.updateSettings(OfflineEffectSettings(kind: .realtimeLeveler, unit: unit))
            try await Task.sleep(for: .milliseconds(50))
        }
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
        precondition(preview.rendered!.settings.parameters["outputGain"] == -4)
        checks.append(["test": "rapid_knob_edits_only_publish_latest_preview", "passed": true])

        var referenceDescription = description
        referenceDescription.componentSubType = 0x64796c76
        let referenceUnit = try await AVAudioUnit.instantiate(with: referenceDescription, options: .loadOutOfProcess)
        let referenceSettings = OfflineEffectSettings(kind: .referenceLeveler, unit: referenceUnit.auAudioUnit)
        let longInfo = try await MediaPreviewRenderer.inspect(source: long)
        let excerpt = try await MediaPreviewRenderer.prepare(info: longInfo, trackID: longInfo.tracks[0].id, start: 0)
        defer { try? FileManager.default.removeItem(at: excerpt.directory) }
        let excerptResult = try await MediaPreviewRenderer.render(input: excerpt, settings: referenceSettings)
        let full = excerpt.directory.appendingPathComponent("full-reference.caf")
        try await OfflineAudioProcessor.render(source: long, destination: full, settings: referenceSettings) { _, _ in }
        let cropped = excerpt.directory.appendingPathComponent("full-first12s.caf")
        try MediaPreviewRenderer.copySegment(source: full, destination: cropped, offset: 0, frames: excerpt.frames)
        precondition(tryEqualPCM(cropped, excerptResult.url))
        checks.append(["test": "lookahead_preview_with_real_following_context_matches_full_render_first12s", "passed": true])

        preview.setExporting(true)
        let previewSource = preview.source
        preview.load(source: audio)
        precondition(preview.source == previewSource)
        preview.setExporting(false)
        let lastDirectory = preview.input!.directory
        preview.clear()
        queue.clear()
        precondition(!preview.isReady && preview.source == nil && queue.jobs.isEmpty)
        precondition(!FileManager.default.fileExists(atPath: lastDirectory.path))
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        precondition(after == before)
        checks.append(["test": "preview_and_parameter_edits_never_write_source_directory", "passed": true])
        let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS \(checks.count) preview workflow checks")
        withExtendedLifetime(av) {}
        withExtendedLifetime(referenceUnit) {}
    }

    static func tryEqualPCM(_ a: URL, _ b: URL) -> Bool {
        do {
            let x = try AVAudioFile(forReading: a, commonFormat: .pcmFormatFloat32, interleaved: false)
            let y = try AVAudioFile(forReading: b, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard x.length == y.length, x.processingFormat == y.processingFormat,
                  let xb = AVAudioPCMBuffer(pcmFormat: x.processingFormat, frameCapacity: 4096),
                  let yb = AVAudioPCMBuffer(pcmFormat: y.processingFormat, frameCapacity: 4096) else { return false }
            while x.framePosition < x.length {
                try x.read(into: xb); try y.read(into: yb)
                guard xb.frameLength == yb.frameLength else { return false }
                for channel in 0 ..< Int(x.processingFormat.channelCount) {
                    if memcmp(xb.floatChannelData![channel], yb.floatChannelData![channel], Int(xb.frameLength) * 4) != 0 { return false }
                }
            }
            return true
        } catch { return false }
    }
}

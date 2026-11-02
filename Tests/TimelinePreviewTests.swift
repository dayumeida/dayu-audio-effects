import AVFoundation
import Foundation

@main struct TimelinePreviewTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("Timeline test failed: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func waitUntil(_ condition: @MainActor () -> Bool, timeout: Double = 45) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw OfflineMediaError.message("时间线状态等待超时。") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    @MainActor static func run() async throws {
        var checks: [[String: Any]] = []
        func pass(_ name: String) { checks.append(["test": name, "passed": true]); print("PASS \(name)") }
        var viewport = AudioTimelineViewport()
        viewport.reset(duration: 2642.73)
        precondition(viewport.start == 0 && viewport.span == 2642.73)
        let anchor = 396.4649206349206
        let anchorFraction = viewport.fraction(at: anchor)
        viewport.zoom(factor: 8, anchor: anchor)
        precondition(abs(viewport.fraction(at: anchor) - anchorFraction) < 1e-9)
        precondition(abs(viewport.time(at: anchorFraction) - anchor) < 1e-9)
        pass("zoom_and_hit_testing_preserve_absolute_time_anchor")
        viewport.pan(by: -100000); precondition(viewport.start == 0)
        viewport.pan(by: 100000); precondition(abs(viewport.end - viewport.total) < 1e-9)
        viewport.zoom(factor: 1e12, anchor: viewport.start)
        precondition(abs(viewport.span - 0.1) < 1e-9)
        viewport.fit(); precondition(viewport.start == 0 && viewport.span == viewport.total)
        pass("pan_clamps_at_both_ends_and_fit_restores_whole_media")
        precondition(abs(TimelineTime.parse("06:36.465")! - 396.465) < 1e-9)
        precondition(TimelineTime.parse("01:02:03.5") == 3723.5 && TimelineTime.parse("396.465") == 396.465)
        precondition(TimelineTime.parse("-1") == nil && TimelineTime.parse("0:75") == nil && TimelineTime.parse("NaN") == nil)
        precondition(TimelineTime.string(396.465, precise: true) == "06:36.465")
        precondition(TimelineTime.string(59.9999, precise: true) == "01:00.000")
        pass("timecode_entry_supports_precise_minutes_seconds_and_rejects_invalid_input")
        let index = TimelineWaveformIndex(peaks: [0.1, 0.8, 0.2, 0.4, 0.9], binDuration: 1, duration: 5)
        precondition(index.peak(from: 0, to: 5) == 0.9 && index.peak(from: 1, to: 2) == 0.8)
        precondition(index.peak(from: 4, to: 5) == 0.9)
        pass("multiresolution_peak_index_preserves_transients_at_fit_and_zoom")

        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dayu-timeline-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let silent = temporary.appendingPathComponent("silent.wav")
        try makeSilent(silent)
        let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: 0x64796c6c,
            componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
        let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
        let preview = MediaPreviewModel()
        preview.updateSettings(OfflineEffectSettings(kind: .realtimeLeveler, unit: av.auAudioUnit))
        preview.load(source: silent)
        try await ready(preview)
        try await waitUntil { !preview.isOverviewLoading && preview.overview != nil }
        precondition(abs(preview.viewport.total - 21) < 1e-6 && preview.overview!.peakDB <= -119)
        pass("whole_media_waveform_and_initial_fit_load_without_export")
        let originalID = preview.input!.id
        preview.zoom(factor: 4)
        preview.panTimeline(by: 3)
        precondition(preview.input!.id == originalID && preview.isReady)
        precondition(!preview.followsPlayhead)
        pass("zoom_and_scroll_never_restart_dsp_preview")
        preview.seek(to: 6.375, version: .processed, autoplay: false)
        precondition(preview.input!.id == originalID && preview.playheadTime == 6.375 && !preview.isPlaying)
        pass("seek_within_cached_audio_is_sample_positioned_without_rerender")
        preview.seek(to: 20.875, version: .processed, autoplay: false)
        try await ready(preview)
        precondition(abs(preview.playheadTime - 20.875) < 1e-6 && abs(preview.input!.start - 9) < 1e-6)
        pass("near_end_seek_plays_target_in_overlapping_final_buffer_not_buffer_start")
        preview.seek(to: 0, version: .processed, autoplay: false)
        try await ready(preview)
        preview.seek(to: 11.0, version: .processed)
        try await waitUntil({ preview.isPlaying && preview.playheadTime > 12.3 }, timeout: 8)
        precondition(preview.playheadTime < 14 && abs(preview.input!.start - 9) < 1e-6)
        preview.stopPlayback()
        let paused = preview.playheadTime
        try await Task.sleep(for: .milliseconds(120))
        precondition(abs(preview.playheadTime - paused) < 1e-6)
        pass("click_playback_continues_past_12s_boundary_and_pause_keeps_cursor")
        preview.play(.original)
        try await waitUntil { preview.playingVersion == .original }
        precondition(abs(preview.playheadTime - paused) < 0.2)
        preview.play(.processed)
        try await waitUntil { preview.playingVersion == .processed }
        precondition(abs(preview.playheadTime - paused) < 0.4)
        preview.stopPlayback()
        pass("original_effect_switch_uses_same_absolute_playhead")
        preview.seek(to: 3, version: .processed)
        preview.seek(to: 17, version: .processed)
        preview.seek(to: 2.5, version: .processed)
        try await waitUntil { preview.isPlaying && preview.playheadTime >= 2.5 }
        precondition(preview.playheadTime < 4)
        preview.stopPlayback()
        pass("rapid_clicks_cancel_stale_seek_and_only_play_latest_target")

        let video = root.appendingPathComponent("H264_AAC_错位音轨.mp4")
        preview.load(source: video)
        try await ready(preview)
        try await waitUntil { preview.overview != nil && !preview.isOverviewLoading }
        precondition(preview.overview!.peak(from: 0, to: 0.3) < 1e-5)
        precondition(preview.overview!.peak(from: 0.4, to: 1) > 0.01)
        pass("video_overview_preserves_audio_track_start_offset")
        preview.zoom(factor: 4, anchor: 1)
        preview.seek(to: 1.2, version: .processed, autoplay: false)
        let timeBeforeSettings = preview.playheadTime
        av.auAudioUnit.parameterTree!.allParameters.first(where: { $0.identifier == "outputGain" })!.value = -6
        preview.updateSettings(OfflineEffectSettings(kind: .realtimeLeveler, unit: av.auAudioUnit))
        precondition(preview.processedRegions.isEmpty)
        try await ready(preview)
        precondition(preview.playheadTime == timeBeforeSettings && !preview.processedRegions.isEmpty)
        pass("parameter_edit_keeps_cursor_and_invalidates_processed_waveform_regions")
        let temporaryCaller = Task { @MainActor in
            preview.seek(to: 1.7, version: .processed, autoplay: false)
            preview.refresh()
            try? await Task.sleep(for: .seconds(5))
        }
        await Task.yield()
        temporaryCaller.cancel()
        try await ready(preview)
        precondition(abs(preview.playheadTime - 1.7) < 1e-6 && !preview.isRendering)
        pass("render_completion_outlives_transient_ui_task_and_clears_busy_state")
        preview.clear()
        precondition(preview.overview == nil && preview.processedRegions.isEmpty && preview.viewport.total == 0)
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        precondition(before == after)
        pass("timeline_navigation_and_audition_never_write_source_directory")
        let data = try JSONSerialization.data(withJSONObject: checks, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
        print("PASS \(checks.count) timeline preview checks")
        withExtendedLifetime(av) {}
    }
    @MainActor static func ready(_ preview: MediaPreviewModel) async throws {
        try await waitUntil { preview.isReady || preview.error != nil }
        if let error = preview.error { throw OfflineMediaError.message(error) }
    }
    static func makeSilent(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        var remaining = 21 * 48000
        while remaining > 0 {
            let count = min(4096, remaining)
            buffer.frameLength = AVAudioFrameCount(count)
            memset(buffer.floatChannelData![0], 0, count * 4)
            try file.write(from: buffer)
            remaining -= count
        }
    }
}

import AVFoundation

nonisolated struct PreviewAudioTrack: Identifiable, Sendable {
    let id: CMPersistentTrackID
    let sampleRate: Double
    let channels: AVAudioChannelCount
    let title: String
}

nonisolated struct PreviewMediaInfo: Sendable {
    let source: URL
    let duration: Double
    let tracks: [PreviewAudioTrack]
    let isVideo: Bool
}

nonisolated struct PreviewWaveform: Sendable {
    let peaks: [Float]
    let peakDB: Double
    var detailPeaks: [Float] = []
}

nonisolated struct PreparedMediaPreview: Sendable {
    let id = UUID()
    let info: PreviewMediaInfo
    let trackID: CMPersistentTrackID
    let directory: URL
    let contextURL: URL
    let originalURL: URL
    let start: Double
    let duration: Double
    let offset: AVAudioFramePosition
    let frames: AVAudioFramePosition
    let originalWaveform: PreviewWaveform
}

nonisolated struct RenderedMediaPreview: Sendable {
    let inputID: UUID
    let settings: OfflineEffectSettings
    let url: URL
    let waveform: PreviewWaveform
}

/// Preview files live exclusively in the App's temporary directory. Import and
/// parameter changes never call the publishing renderer or touch the source folder.
enum MediaPreviewRenderer {
    nonisolated static func inspect(source: URL) async throws -> PreviewMediaInfo {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL,
              try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw OfflineMediaError.message("请选择本地音频或视频文件。")
        }
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw OfflineMediaError.message("素材时长无效。") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else { throw OfflineMediaError.message("素材没有可预览的音轨。") }
        var tracks: [PreviewAudioTrack] = []
        for (index, track) in audioTracks.enumerated() {
            guard let description = try await track.load(.formatDescriptions).first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw OfflineMediaError.message("无法读取音轨格式。")
            }
            tracks.append(PreviewAudioTrack(id: track.trackID, sampleRate: asbd.mSampleRate,
                channels: asbd.mChannelsPerFrame,
                title: "音轨 \(index + 1) · \(Int(asbd.mSampleRate)) Hz · \(asbd.mChannelsPerFrame) 声道"))
        }
        return PreviewMediaInfo(source: source, duration: duration, tracks: tracks,
                                isVideo: try await !asset.loadTracks(withMediaType: .video).isEmpty)
    }

    nonisolated static func prepare(info: PreviewMediaInfo, trackID: CMPersistentTrackID,
                                    start requestedStart: Double) async throws -> PreparedMediaPreview {
        try Task.checkCancellation()
        let source = info.source
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let trackInfo = info.tracks.first(where: { $0.id == trackID }),
              (1 ... 2).contains(trackInfo.channels) else {
            throw OfflineMediaError.message("预览支持单声道和立体声音轨。")
        }
        let rate = trackInfo.sampleRate
        guard rate.isFinite, (8_000 ... 384_000).contains(rate) else {
            throw OfflineMediaError.message("此音轨的采样率不受支持。")
        }
        let start = (min(max(0, requestedStart), max(0, info.duration - 12)) * rate).rounded() / rate
        let duration = min(12, info.duration - start)
        let contextStart = max(0, start - 10)
        let frames = AVAudioFramePosition((duration * rate).rounded())
        let offset = AVAudioFramePosition(((start - contextStart) * rate).rounded())
        // Look-ahead effects also need real audio after the audition range;
        // flushing an abruptly truncated excerpt would change its last seconds.
        let following = AVAudioFramePosition((min(10, max(0, info.duration - start - duration)) * rate).rounded())
        guard frames > 0 else { throw OfflineMediaError.message("预览片段没有音频采样。") }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dayu-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let asset = AVURLAsset(url: source)
            guard let track = try await asset.loadTracks(withMediaType: .audio).first(where: { $0.trackID == trackID }) else {
                throw OfflineMediaError.message("所选音轨已无法读取。")
            }
            let context = directory.appendingPathComponent("context.caf")
            let original = directory.appendingPathComponent("original.caf")
            try decode(asset: asset, track: track, trackInfo: trackInfo, start: contextStart,
                       frames: offset + frames + following, destination: context)
            try copySegment(source: context, destination: original, offset: offset, frames: frames)
            let waveform = try waveform(source: original)
            try Task.checkCancellation()
            return PreparedMediaPreview(info: info, trackID: trackID, directory: directory,
                contextURL: context, originalURL: original, start: start, duration: Double(frames) / rate,
                offset: offset, frames: frames, originalWaveform: waveform)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    nonisolated static func render(input: PreparedMediaPreview, settings: OfflineEffectSettings) async throws -> RenderedMediaPreview {
        let token = UUID().uuidString
        let context = input.directory.appendingPathComponent("wet-context-\(token).caf")
        let output = input.directory.appendingPathComponent("preview-\(token).caf")
        defer { try? FileManager.default.removeItem(at: context) }
        do {
            try await OfflineAudioProcessor.render(source: input.contextURL, destination: context, settings: settings) { _, _ in }
            try Task.checkCancellation()
            try copySegment(source: context, destination: output, offset: input.offset, frames: input.frames)
            let waveform = try waveform(source: output)
            try Task.checkCancellation()
            return RenderedMediaPreview(inputID: input.id, settings: settings, url: output, waveform: waveform)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    nonisolated private static func decode(asset: AVAsset, track: AVAssetTrack, trackInfo: PreviewAudioTrack,
                                            start: Double, frames: AVAudioFramePosition, destination: URL) throws {
        let rate = trackInfo.sampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                         channels: trackInfo.channels, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw OfflineMediaError.message("无法分配预览音频缓冲区。")
        }
        let origin = CMTime(seconds: start, preferredTimescale: CMTimeScale(rate.rounded()))
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = CMTimeRange(start: origin, duration: CMTime(value: frames, timescale: CMTimeScale(rate.rounded())))
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: trackInfo.channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(output) else { throw OfflineMediaError.message("无法分离预览音轨。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? OfflineMediaError.message("无法读取预览音轨。") }
        defer { reader.cancelReading() }
        let writer = try AVAudioFile(forWriting: destination, settings: format.settings,
                                     commonFormat: .pcmFormatFloat32, interleaved: true)
        var cursor: AVAudioFramePosition = 0
        func silence(to target: AVAudioFramePosition) throws {
            while cursor < min(frames, target) {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(4096, min(frames, target) - cursor))
                buffer.frameLength = count
                memset(buffer.floatChannelData![0], 0, Int(count) * Int(format.channelCount) * 4)
                try writer.write(from: buffer)
                cursor += AVAudioFramePosition(count)
            }
        }
        while true {
            let advanced = try autoreleasepool { () throws -> Bool in
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample)
                guard pts.isNumeric else { throw OfflineMediaError.message("预览音轨的时间戳无效。") }
                let position = AVAudioFramePosition(((pts - origin).seconds * rate).rounded())
                try silence(to: position)
                var offset = max(0, cursor - position)
                let sampleFrames = AVAudioFramePosition(CMSampleBufferGetNumSamples(sample))
                while offset < sampleFrames && cursor < frames {
                    try Task.checkCancellation()
                    let count = min(4096, sampleFrames - offset, frames - cursor)
                    buffer.frameLength = AVAudioFrameCount(count)
                    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset),
                        frameCount: Int32(count), into: buffer.mutableAudioBufferList)
                    guard status == noErr else { throw OfflineMediaError.message("预览音轨解码失败（\(status)）。") }
                    try writer.write(from: buffer)
                    cursor += count
                    offset += count
                }
                return true
            }
            if !advanced { break }
        }
        guard reader.status == .completed else { throw reader.error ?? OfflineMediaError.message("预览音轨读取失败。") }
        try silence(to: frames)
    }

    nonisolated static func copySegment(source: URL, destination: URL, offset: AVAudioFramePosition,
                                        frames: AVAudioFramePosition) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard offset >= 0, frames > 0, offset + frames <= file.length else {
            throw OfflineMediaError.message("预览片段超出音频范围。")
        }
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw OfflineMediaError.message("无法分配预览缓冲区。")
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let writer = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        file.framePosition = offset
        var remaining = frames
        while remaining > 0 {
            try Task.checkCancellation()
            let count = AVAudioFrameCount(min(4096, remaining))
            try file.read(into: buffer, frameCount: count)
            guard buffer.frameLength == count else { throw OfflineMediaError.message("预览音频读取不完整。") }
            try writer.write(from: buffer)
            remaining -= AVAudioFramePosition(count)
        }
    }

    nonisolated static func waveform(source: URL, bins: Int = 512) throws -> PreviewWaveform {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else {
            throw OfflineMediaError.message("无法读取预览波形。")
        }
        var peaks = [Float](repeating: 0, count: bins)
        let detailCount = min(32768, Int(file.length))
        var detailPeaks = [Float](repeating: 0, count: detailCount)
        var position: AVAudioFramePosition = 0
        var peak: Float = 0
        while position < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, file.length - position)))
            guard buffer.frameLength > 0 else { throw OfflineMediaError.message("波形读取不完整。") }
            for index in 0 ..< Int(buffer.frameLength) {
                var value: Float = 0
                for channel in 0 ..< Int(file.processingFormat.channelCount) {
                    let sample = buffer.floatChannelData![channel][index]
                    if sample.isFinite { value = max(value, abs(sample)) }
                }
                let bin = min(bins - 1, Int((position + AVAudioFramePosition(index)) * AVAudioFramePosition(bins) / file.length))
                peaks[bin] = max(peaks[bin], value)
                let detailedBin = min(detailCount - 1, Int((position + AVAudioFramePosition(index)) * AVAudioFramePosition(detailCount) / file.length))
                detailPeaks[detailedBin] = max(detailPeaks[detailedBin], value)
                peak = max(peak, value)
            }
            position += AVAudioFramePosition(buffer.frameLength)
        }
        return PreviewWaveform(peaks: peaks, peakDB: 20 * log10(max(1e-6, Double(peak))), detailPeaks: detailPeaks)
    }
}

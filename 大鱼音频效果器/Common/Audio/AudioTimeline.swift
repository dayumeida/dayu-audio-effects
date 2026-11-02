import AVFoundation

nonisolated enum TimelineTime {
    static func string(_ seconds: Double, precise: Bool = false) -> String {
        let safe = max(0, seconds.isFinite ? seconds : 0)
        if precise {
            let milliseconds = Int64((safe * 1000).rounded())
            return String(format: "%02lld:%06.3f", milliseconds / 60000, Double(milliseconds % 60000) / 1000)
        }
        let minutes = Int(safe) / 60
        return String(format: "%02d:%02d", minutes, Int(safe) % 60)
    }
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":", omittingEmptySubsequences: false)
        guard (1 ... 3).contains(parts.count) else { return nil }
        let values = parts.compactMap { Double($0) }
        guard values.count == parts.count, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        if values.count > 1 && values.last! >= 60 { return nil }
        if values.count == 3 && values[1] >= 60 { return nil }
        return values.reduce(0) { $0 * 60 + $1 }
    }
}

/// All display and hit testing uses absolute source time, independent of the
/// short render buffers used to audition expensive effects.
nonisolated struct AudioTimelineViewport: Sendable {
    private(set) var total = 0.0
    private(set) var start = 0.0
    private(set) var span = 1.0
    var end: Double { min(total, start + span) }
    var minimumSpan: Double { min(total, 0.1) }
    var canZoomIn: Bool { total > 0 && span > minimumSpan + 0.00001 }
    var canZoomOut: Bool { span < total - 0.00001 }

    mutating func reset(duration: Double) {
        total = duration.isFinite ? max(0, duration) : 0
        fit()
    }
    mutating func fit() { start = 0; span = max(0.001, total) }
    mutating func zoom(factor: Double, anchor: Double) {
        guard total > 0, factor.isFinite, factor > 0 else { return }
        let focus = min(end, max(start, anchor))
        let fraction = min(1, max(0, (focus - start) / span))
        let newSpan = min(total, max(minimumSpan, span / factor))
        start = min(max(0, total - newSpan), max(0, focus - fraction * newSpan))
        span = newSpan
    }
    mutating func scroll(to time: Double) { start = min(max(0, total - span), max(0, time)) }
    mutating func pan(by seconds: Double) { scroll(to: start + seconds) }
    mutating func reveal(_ time: Double) {
        if time < start || time >= end { scroll(to: time - span * 0.15) }
    }
    func time(at fraction: Double) -> Double { min(total, max(0, start + min(1, max(0, fraction)) * span)) }
    func fraction(at time: Double) -> Double { (time - start) / span }
    var tickInterval: Double {
        let target = span / 6
        let power = pow(10, floor(log10(max(0.0001, target))))
        return [1.0, 2, 5, 10].map { $0 * power }.first(where: { $0 >= target }) ?? power * 10
    }
}

nonisolated struct TimelineWaveformRegion: Sendable {
    let start: Double
    let duration: Double
    let waveform: PreviewWaveform
    var end: Double { start + duration }
    func peak(from lower: Double, to upper: Double) -> Float? {
        guard lower < end, upper > start else { return nil }
        let peaks = waveform.detailPeaks.isEmpty || upper - lower >= duration / Double(waveform.peaks.count)
            ? waveform.peaks : waveform.detailPeaks
        let a = max(0, min(peaks.count - 1, Int((max(lower, start) - start) / duration * Double(peaks.count))))
        let b = max(a + 1, min(peaks.count, Int(ceil((min(upper, end) - start) / duration * Double(peaks.count)))))
        return peaks[a ..< b].max() ?? 0
    }
}

/// A bounded, multiresolution peak index keeps fit-to-window and deep zoom fast
/// even for hour-long media. Compressed audio is decoded once on a worker task.
nonisolated struct TimelineWaveformIndex: Sendable {
    let levels: [[Float]]
    let binDuration: Double
    let duration: Double
    let peakDB: Double

    init(peaks: [Float], binDuration: Double, duration: Double) {
        var levels = [peaks]
        var current = peaks
        while current.count > 1 {
            var reduced: [Float] = []
            reduced.reserveCapacity((current.count + 1) / 2)
            for index in stride(from: 0, to: current.count, by: 2) {
                reduced.append(max(current[index], index + 1 < current.count ? current[index + 1] : 0))
            }
            levels.append(reduced)
            current = reduced
        }
        self.levels = levels
        self.binDuration = binDuration
        self.duration = duration
        peakDB = 20 * log10(max(1e-6, Double(levels.last?.first ?? 0)))
    }

    func peak(from lower: Double, to upper: Double) -> Float {
        let interval = max(binDuration, upper - lower)
        let level = min(levels.count - 1, max(0, Int(floor(log2(interval / binDuration))) - 1))
        let peaks = levels[level]
        let step = binDuration * pow(2, Double(level))
        let a = min(peaks.count - 1, max(0, Int(lower / step)))
        let b = min(peaks.count, max(a + 1, Int(ceil(upper / step))))
        return peaks[a ..< b].max() ?? 0
    }
}

extension MediaPreviewRenderer {
    nonisolated static func overview(info: PreviewMediaInfo, trackID: CMPersistentTrackID,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> TimelineWaveformIndex {
        let scoped = info.source.startAccessingSecurityScopedResource()
        defer { if scoped { info.source.stopAccessingSecurityScopedResource() } }
        guard let trackInfo = info.tracks.first(where: { $0.id == trackID }), (1 ... 2).contains(trackInfo.channels) else {
            throw OfflineMediaError.message("无法读取所选音轨的整段波形。")
        }
        let asset = AVURLAsset(url: info.source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first(where: { $0.trackID == trackID }),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: trackInfo.sampleRate,
                                         channels: trackInfo.channels, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw OfflineMediaError.message("无法创建波形读取缓冲区。")
        }
        let rate = trackInfo.sampleRate
        let binFrames = max(1, Int64(ceil(max(rate * 0.01, info.duration * rate / 2_000_000))))
        let totalFrames = Int64(ceil(info.duration * rate))
        var peaks = [Float](repeating: 0, count: max(1, Int((totalFrames + binFrames - 1) / binFrames)))
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: trackInfo.channels, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(output) else { throw OfflineMediaError.message("无法加载整段波形。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? OfflineMediaError.message("无法读取音轨。") }
        defer { reader.cancelReading() }
        var lastPercent = -1
        while true {
            let advanced = try autoreleasepool { () throws -> Bool in
                try Task.checkCancellation()
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample)
                guard pts.isNumeric else { return true }
                let start = Int64((pts.seconds * rate).rounded())
                let count = Int64(CMSampleBufferGetNumSamples(sample))
                var offset: Int64 = 0
                while offset < count {
                    try Task.checkCancellation()
                    let frames = min(4096, count - offset)
                    buffer.frameLength = AVAudioFrameCount(frames)
                    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset),
                        frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
                    guard status == noErr else { throw OfflineMediaError.message("整段波形解码失败（\(status)）。") }
                    let data = buffer.floatChannelData![0]
                    for frame in 0 ..< Int(frames) {
                        let absolute = start + offset + Int64(frame)
                        guard absolute >= 0, absolute < totalFrames else { continue }
                        var peak: Float = 0
                        for channel in 0 ..< Int(trackInfo.channels) {
                            let value = data[frame * Int(trackInfo.channels) + channel]
                            if value.isFinite { peak = max(peak, abs(value)) }
                        }
                        let bin = Int(absolute / binFrames)
                        peaks[bin] = max(peaks[bin], peak)
                    }
                    offset += frames
                }
                let fraction = min(1, max(0, Double(start + count) / Double(totalFrames)))
                let percent = Int(fraction * 100)
                if percent > lastPercent { lastPercent = percent; progress(fraction) }
                return true
            }
            if !advanced { break }
        }
        guard reader.status == .completed else { throw reader.error ?? OfflineMediaError.message("整段波形读取不完整。") }
        progress(1)
        return TimelineWaveformIndex(peaks: peaks, binDuration: Double(binFrames) / rate, duration: info.duration)
    }
}

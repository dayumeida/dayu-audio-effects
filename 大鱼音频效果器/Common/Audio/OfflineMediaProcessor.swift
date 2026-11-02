import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers

enum OfflineMediaProcessor {
    nonisolated static func process(source: URL, settings: OfflineEffectSettings,
                                    progress: @escaping OfflineAudioProcessor.Progress) async throws -> URL {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL else { throw OfflineMediaError.message("请导入本地音频或视频文件。") }
        let values = try source.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw OfflineMediaError.message("请导入音频或视频文件，不能导入文件夹。") }
        let asset = AVURLAsset(url: source)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let suffix = try videoTracks.isEmpty ? OfflineAudioProcessor.audioExtension(for: source) : videoExtension(source)
        let staging = source.deletingLastPathComponent().appendingPathComponent(".dayu-\(UUID().uuidString).\(suffix)")
        defer { try? FileManager.default.removeItem(at: staging) }
        if videoTracks.isEmpty {
            try await OfflineAudioProcessor.render(source: source, destination: staging, settings: settings, progress: progress)
        } else {
            try await renderVideo(asset: asset, destination: staging, suffix: suffix, settings: settings, progress: progress)
        }
        try Task.checkCancellation()
        return try OfflineAudioProcessor.publish(staging: staging, source: source, effect: settings.kind, extension: suffix)
    }

    nonisolated private static func videoExtension(_ source: URL) throws -> String {
        switch source.pathExtension.lowercased() {
        case "mov": return "mov"
        case "mp4", "m4v": return source.pathExtension.lowercased()
        default:
            throw OfflineMediaError.message("视频支持 MOV、MP4 和 M4V；其他容器暂不支持原轨直通封装。")
        }
    }

    nonisolated private static func renderVideo(asset: AVURLAsset, destination: URL, suffix: String,
                                               settings: OfflineEffectSettings,
                                               progress: @escaping OfflineAudioProcessor.Progress) async throws {
        let tracks = try await asset.load(.tracks)
        let audioTracks = tracks.filter { $0.mediaType == .audio }
        guard !audioTracks.isEmpty else { throw OfflineMediaError.message("视频中没有可处理的音轨。") }
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else { throw OfflineMediaError.message("视频时长无效。") }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("dayu-offline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let fileType: AVFileType = suffix == "mov" ? .mov : (suffix == "m4v" ? .m4v : .mp4)
        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        var clocks: [CMTimeScale] = [duration.timescale]
        for track in tracks { clocks.append(try await track.load(.naturalTimeScale)) }
        writer.movieTimeScale = movieClock(clocks)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.metadata = try await asset.load(.metadata)
        var rendered: [CMPersistentTrackID: (URL, CMTime, [String: Any])] = [:]

        // Check the original audio formats before doing expensive DSP work. Never substitute a codec.
        for track in audioTracks {
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first,
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
                throw OfflineMediaError.message("无法读取视频音轨格式。")
            }
            guard (1 ... 2).contains(asbd.mChannelsPerFrame) else {
                throw OfflineMediaError.message("视频包含多声道音轨，现有效果器仅支持单声道和立体声，未导出副本。")
            }
            guard descriptions.allSatisfy({ CMFormatDescriptionEqual($0, otherFormatDescription: description) }) else {
                throw OfflineMediaError.message("音轨中途切换了编码格式，暂不支持保持原格式导出。")
            }
            let rate = try await track.load(.estimatedDataRate)
            let encoding = try audioSettings(asbd: asbd, description: description, bitRate: rate)
            guard writer.canApply(outputSettings: encoding, forMediaType: .audio) else {
                throw OfflineMediaError.message("系统无法按原音频编码或码率导出此视频（\(fourCC(asbd.mFormatID))），未转换为其他格式。")
            }
            let range = try await track.load(.timeRange)
            rendered[track.trackID] = (temporary.appendingPathComponent("encoded-\(track.trackID).mov"), range.start, encoding)
        }

        for (index, track) in audioTracks.enumerated() {
            try Task.checkCancellation()
            let raw = temporary.appendingPathComponent("source-\(track.trackID).caf")
            let pcm = temporary.appendingPathComponent("processed-\(track.trackID).caf")
            let base = Double(index) / Double(audioTracks.count) * 0.8
            let span = 0.8 / Double(audioTracks.count)
            progress(base, "正在分离音轨 \(index + 1)/\(audioTracks.count)")
            let origin = try await extract(track: track, asset: asset, destination: raw) { value, _ in
                progress(base + value * span * 0.15, "正在分离音轨 \(index + 1)/\(audioTracks.count)")
            }
            let planned = rendered[track.trackID]!
            rendered[track.trackID] = (planned.0, origin, planned.2)
            try await OfflineAudioProcessor.render(source: raw, destination: pcm, settings: settings) { value, _ in
                progress(base + span * (0.15 + value * 0.7), "正在处理音轨 \(index + 1)/\(audioTracks.count)")
            }
            let encoded = rendered[track.trackID]!
            try await encodeAudio(source: pcm, destination: encoded.0, encoding: encoded.2) { value, _ in
                progress(base + span * (0.85 + value * 0.15), "正在按原格式编码音轨 \(index + 1)/\(audioTracks.count)")
            }
            try FileManager.default.removeItem(at: raw)
            try FileManager.default.removeItem(at: pcm)
        }

        // Every non-audio track is passed through as its original compressed sample buffers.
        var streams: [MuxStream] = []
        for track in tracks {
            try Task.checkCancellation()
            let reader: AVAssetReader
            let output: AVAssetReaderTrackOutput
            let input: AVAssetWriterInput
            let offset: CMTime
            if let (url, start, _) = rendered[track.trackID] {
                let processed = AVURLAsset(url: url)
                guard let pcmTrack = try await processed.loadTracks(withMediaType: .audio).first,
                      let description = try await pcmTrack.load(.formatDescriptions).first else {
                    throw OfflineMediaError.message("处理后的音轨无法读取。")
                }
                reader = try AVAssetReader(asset: processed)
                output = AVAssetReaderTrackOutput(track: pcmTrack, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: description)
                offset = start - (try await pcmTrack.load(.timeRange)).start
            } else {
                guard let description = try await track.load(.formatDescriptions).first else {
                    throw OfflineMediaError.message("视频含无法直通封装的轨道，已停止导出。")
                }
                reader = try AVAssetReader(asset: asset)
                output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: description)
                offset = .zero
                if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
                input.mediaTimeScale = try await track.load(.naturalTimeScale)
            }
            input.expectsMediaDataInRealTime = false
            input.metadata = try await track.load(.metadata)
            input.languageCode = try await track.load(.languageCode)
            if let tag = try await track.load(.extendedLanguageTag) { input.extendedLanguageTag = tag }
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output), writer.canAdd(input) else {
                throw OfflineMediaError.message("此视频的轨道无法在原容器中完整保留，已停止导出。")
            }
            reader.add(output)
            writer.add(input)
            streams.append(MuxStream(reader: reader, output: output, input: input, offset: offset))
        }
        try await write(streams: streams, writer: writer, duration: duration) { value, _ in
            progress(0.8 + value * 0.2, "正在合并音轨 · 视频原轨复制")
        }
        progress(1, "视频副本已生成")
    }

    /// Encode audio separately so a delayed track keeps its original edit-list
    /// offset. Encoding directly into the final movie would insert leading silence.
    nonisolated private static func encodeAudio(source: URL, destination: URL, encoding: [String: Any],
                                                progress: @escaping OfflineAudioProcessor.Progress) async throws {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let description = try await track.load(.formatDescriptions).first else {
            throw OfflineMediaError.message("无法读取待编码的音轨。")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mov)
        writer.movieTimeScale = try await track.load(.naturalTimeScale)
        defer { if writer.status == .writing { writer.cancelWriting() } }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: encoding, sourceFormatHint: description)
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw OfflineMediaError.message("系统无法按原音轨格式编码。")
        }
        reader.add(output)
        writer.add(input)
        try await write(streams: [MuxStream(reader: reader, output: output, input: input, offset: .zero)],
                        writer: writer, duration: asset.load(.duration), progress: progress)
    }

    nonisolated private static func write(streams: [MuxStream], writer: AVAssetWriter, duration: CMTime,
                                          progress: OfflineAudioProcessor.Progress) async throws {
        guard writer.startWriting() else { throw writer.error ?? OfflineMediaError.message("无法创建输出副本。") }
        writer.startSession(atSourceTime: .zero)
        for stream in streams {
            guard stream.reader.startReading() else { throw stream.reader.error ?? OfflineMediaError.message("无法读取封装轨道。") }
        }
        defer { streams.forEach { $0.reader.cancelReading() } }
        var completed = Set<Int>()
        var lastProgress = -1
        var lastActivity = Date()
        while completed.count < streams.count {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? OfflineMediaError.message("视频封装失败。") }
            var advanced = false
            for (index, stream) in streams.enumerated() where !completed.contains(index) && stream.input.isReadyForMoreMediaData {
                try autoreleasepool {
                    guard let sample = stream.output.copyNextSampleBuffer() else {
                        guard stream.reader.status == .completed else {
                            throw stream.reader.error ?? OfflineMediaError.message("源轨道读取不完整。")
                        }
                        stream.input.markAsFinished()
                        completed.insert(index)
                        advanced = true
                        return
                    }
                    advanced = true
                    // Reader edit-boundary/empty-media markers have no encoded
                    // samples. Passing terminal markers to Writer extends video.
                    guard CMSampleBufferGetNumSamples(sample) > 0 else { return }
                    let buffer = try shifted(sample, by: stream.offset)
                    guard stream.input.append(buffer) else { throw writer.error ?? OfflineMediaError.message("轨道写入失败。") }
                    advanced = true
                    let fraction = min(1, max(0, CMSampleBufferGetOutputPresentationTimeStamp(buffer).seconds / duration.seconds))
                    let percent = Int(fraction * 100)
                    if percent > lastProgress {
                        lastProgress = percent
                        progress(fraction, "正在写入轨道")
                    }
                }
            }
            if advanced { lastActivity = Date() }
            else {
                guard Date().timeIntervalSince(lastActivity) < 60 else { throw OfflineMediaError.message("视频封装长时间无响应，已停止导出。") }
                try await Task.sleep(for: .milliseconds(5))
            }
        }
        // Let the original sample durations end each track. Forcing an asset-wide
        // endSession extends the last decode-order packet of B-frame video.
        await writer.finishWriting()
        try Task.checkCancellation()
        guard writer.status == .completed else { throw writer.error ?? OfflineMediaError.message("视频封装未完成。") }
        progress(1, "轨道写入完成")
    }

    nonisolated private struct MuxStream {
        let reader: AVAssetReader
        let output: AVAssetReaderTrackOutput
        let input: AVAssetWriterInput
        let offset: CMTime
    }

    nonisolated private static func audioSettings(asbd: AudioStreamBasicDescription, description: CMFormatDescription,
                                                  bitRate: Float) throws -> [String: Any] {
        var result: [String: Any] = [AVFormatIDKey: asbd.mFormatID, AVSampleRateKey: asbd.mSampleRate,
                                   AVNumberOfChannelsKey: asbd.mChannelsPerFrame]
        var size = 0
        if let layout = CMAudioFormatDescriptionGetChannelLayout(description, sizeOut: &size), size > 0 {
            result[AVChannelLayoutKey] = Data(bytes: layout, count: size)
        } else {
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = asbd.mChannelsPerFrame == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
            result[AVChannelLayoutKey] = withUnsafeBytes(of: &layout) { Data($0) }
        }
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            result[AVLinearPCMBitDepthKey] = asbd.mBitsPerChannel
            result[AVLinearPCMIsFloatKey] = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            result[AVLinearPCMIsBigEndianKey] = (asbd.mFormatFlags & kAudioFormatFlagIsBigEndian) != 0
            result[AVLinearPCMIsNonInterleaved] = false
        case kAudioFormatAppleLossless:
            let depths: [UInt32: Int] = [1: 16, 2: 20, 3: 24, 4: 32]
            result[AVEncoderBitDepthHintKey] = depths[asbd.mFormatFlags] ?? Int(asbd.mBitsPerChannel)
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
             kAudioFormatMPEG4AAC_LD, kAudioFormatMPEG4AAC_ELD:
            guard bitRate.isFinite, bitRate > 0 else {
                throw OfflineMediaError.message("无法取得原音轨码率，未更改编码参数。")
            }
            result[AVEncoderBitRateKey] = Int(bitRate.rounded())
            result[AVEncoderBitRateStrategyKey] = AVAudioBitRateStrategy_Constant
        default:
            throw OfflineMediaError.message("暂不支持按原音频编码 \(fourCC(asbd.mFormatID)) 导出视频；原文件未修改。")
        }
        return result
    }

    /// Decode only audio, keeping its original start time, gaps and exact track length.
    nonisolated private static func extract(track: AVAssetTrack, asset: AVAsset, destination: URL,
                                            progress: OfflineAudioProcessor.Progress) async throws -> CMTime {
        let description = try await track.load(.formatDescriptions).first!
        let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
        let range = try contentRange(track: track, asset: asset)
        let rate = asbd.mSampleRate
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                        channels: asbd.mChannelsPerFrame, interleaved: true),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw OfflineMediaError.message("无法创建音轨缓冲区。")
        }
        let reader = try AVAssetReader(asset: asset)
        reader.timeRange = range
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: rate, AVNumberOfChannelsKey: asbd.mChannelsPerFrame, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false])
        guard reader.canAdd(output) else { throw OfflineMediaError.message("无法分离视频音轨。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? OfflineMediaError.message("无法解码视频音轨。") }
        defer { reader.cancelReading() }
        var pending = output.copyNextSampleBuffer()
        guard let first = pending else { throw reader.error ?? OfflineMediaError.message("视频音轨为空。") }
        let origin = CMSampleBufferGetPresentationTimeStamp(first)
        guard origin.isNumeric else { throw OfflineMediaError.message("音轨时间戳无效。") }
        let total = Int64(((range.end - origin).seconds * rate).rounded())
        guard total > 0 else { throw OfflineMediaError.message("视频音轨为空。") }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: true)
        var cursor: Int64 = 0
        var lastPercent = -1
        func silence(to target: Int64) throws {
            while cursor < min(target, total) {
                try Task.checkCancellation()
                let count = min(Int64(buffer.frameCapacity), min(target, total) - cursor)
                buffer.frameLength = AVAudioFrameCount(count)
                memset(buffer.floatChannelData![0], 0, Int(count) * Int(format.channelCount) * 4)
                try file.write(from: buffer)
                cursor += count
            }
        }
        while let sample = pending {
            try Task.checkCancellation()
            try autoreleasepool {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                guard pts.isNumeric else { throw OfflineMediaError.message("音轨时间戳无效。") }
                let start = Int64(((pts - origin).seconds * rate).rounded())
                try silence(to: start)
                var offset = max(Int64(0), cursor - start)
                let samples = Int64(CMSampleBufferGetNumSamples(sample))
                while offset < samples && cursor < total {
                    try Task.checkCancellation()
                    let count = min(Int64(buffer.frameCapacity), samples - offset, total - cursor)
                    buffer.frameLength = AVAudioFrameCount(count)
                    let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset),
                        frameCount: Int32(count), into: buffer.mutableAudioBufferList)
                    guard status == noErr else { throw OfflineMediaError.message("音轨解码失败（\(status)）。") }
                    try file.write(from: buffer)
                    cursor += count
                    offset += count
                }
                let percent = Int(Double(cursor) / Double(total) * 100)
                if percent != lastPercent { lastPercent = percent; progress(Double(cursor) / Double(total), "正在分离音轨") }
            }
            pending = output.copyNextSampleBuffer()
        }
        guard reader.status == .completed else { throw reader.error ?? OfflineMediaError.message("音轨读取失败。") }
        try silence(to: total)
        return origin
    }

    nonisolated private static func shifted(_ sample: CMSampleBuffer, by offset: CMTime) throws -> CMSampleBuffer {
        guard offset != .zero else { return sample }
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr else { throw OfflineMediaError.message("无法读取音轨时间信息。") }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(sample, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        guard status == noErr else { throw OfflineMediaError.message("无法读取音轨时间信息。") }
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid { timings[index].presentationTimeStamp = timings[index].presentationTimeStamp + offset }
            if timings[index].decodeTimeStamp.isValid { timings[index].decodeTimeStamp = timings[index].decodeTimeStamp + offset }
        }
        var copy: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &copy)
        guard status == noErr, let copy else { throw OfflineMediaError.message("无法对齐处理后的音轨。") }
        // Reader can provide output timing overrides for edit lists and codec
        // priming. New sample timing alone does not shift those overrides.
        status = CMSampleBufferSetOutputPresentationTimeStamp(copy,
            newValue: CMSampleBufferGetOutputPresentationTimeStamp(sample) + offset)
        guard status == noErr else { throw OfflineMediaError.message("无法保留音轨起始偏移。") }
        return copy
    }

    nonisolated private static func contentRange(track: AVAssetTrack, asset: AVAsset) throws -> CMTimeRange {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw OfflineMediaError.message("无法读取原音轨时间信息。") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? OfflineMediaError.message("无法读取音轨。") }
        defer { reader.cancelReading() }
        var start: CMTime?
        var end: CMTime?
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
            let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            let duration = CMSampleBufferGetOutputDuration(sample)
            guard pts.isNumeric, duration.isNumeric else { throw OfflineMediaError.message("音轨时间信息无效。") }
            start = start.map { CMTimeMinimum($0, pts) } ?? pts
            end = end.map { CMTimeMaximum($0, pts + duration) } ?? (pts + duration)
        }
        guard reader.status == .completed else { throw reader.error ?? OfflineMediaError.message("音轨读取不完整。") }
        guard let start, let end, end > start else { throw OfflineMediaError.message("视频音轨为空。") }
        return CMTimeRange(start: start, end: end)
    }

    nonisolated private static func fourCC(_ value: UInt32) -> String {
        String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? "\(value)"
    }

    nonisolated private static func movieClock(_ clocks: [CMTimeScale]) -> CMTimeScale {
        func gcd(_ a: Int64, _ b: Int64) -> Int64 { b == 0 ? a : gcd(b, a % b) }
        var result: Int64 = 1
        for clock in clocks where clock > 0 {
            let next = result / gcd(result, Int64(clock)) * Int64(clock)
            // Unusual clocks still get sub-microsecond edit-list precision.
            if next > Int64(Int32.max) { return 1_000_000_000 }
            result = next
        }
        return CMTimeScale(result)
    }
}

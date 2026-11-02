import AVFoundation
import AudioToolbox
import OSLog

/// A batch uses one immutable snapshot of the editor, including its bypass state.
struct OfflineEffectSettings: Sendable, Equatable {
    let kind: DayuEffectKind
    let parameters: [String: Float]
    let bypass: Bool

    @MainActor init(kind: DayuEffectKind, unit: AUAudioUnit) {
        self.kind = kind
        parameters = Dictionary(uniqueKeysWithValues: (unit.parameterTree?.allParameters ?? [])
            .filter { $0.flags.contains(.flag_IsWritable) }.map { ($0.identifier, $0.value) })
        bypass = unit.shouldBypassEffect
    }
}

enum OfflineMediaError: LocalizedError {
    case message(String)
    nonisolated var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}

enum OfflineAudioProcessor {
    typealias Progress = @Sendable (Double, String) -> Void

    /// Dedicated AU instance: the offline job never borrows the preview engine's state.
    nonisolated static func render(source: URL, destination: URL, settings: OfflineEffectSettings,
                                   progress: @escaping Progress) async throws {
        try Task.checkCancellation()
        let description = AudioComponentDescription(componentType: 0x61756678,
            componentSubType: settings.kind.subtype, componentManufacturer: 0x44617975,
            componentFlags: 0, componentFlagsMask: 0)
        let trace = Logger(subsystem: "media.dayu.audio.leveler", category: "timeline-preview")
        trace.debug("AU instantiate start \(settings.kind.rawValue, privacy: .public)")
        let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
        trace.debug("AU instantiate returned \(settings.kind.rawValue, privacy: .public)")
        try Task.checkCancellation()
        try withExtendedLifetime(av) {
            try render(source: source, destination: destination, settings: settings, unit: av.auAudioUnit,
                       progress: progress)
        }
    }

    nonisolated private static func render(source: URL, destination: URL, settings: OfflineEffectSettings,
                                           unit: AUAudioUnit, progress: Progress) throws {
        let file = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (1 ... 2).contains(format.channelCount) else {
            throw OfflineMediaError.message("现有效果器支持单声道和立体声；此音轨未处理。")
        }
        guard file.length > 0 else { throw OfflineMediaError.message("音频没有可处理的采样。") }
        guard (settings.kind.minimumSampleRate ... 384_000).contains(format.sampleRate) else {
            throw OfflineMediaError.message("当前效果器不支持此音轨的采样率（\(Int(format.sampleRate)) Hz）。")
        }
        try unit.inputBusses[0].setFormat(format)
        try unit.outputBusses[0].setFormat(format)
        unit.maximumFramesToRender = 4096
        unit.isRenderingOffline = true
        for parameter in unit.parameterTree?.allParameters ?? [] {
            if parameter.flags.contains(.flag_IsWritable), let value = settings.parameters[parameter.identifier] {
                parameter.value = value
            }
        }
        unit.shouldBypassEffect = settings.bypass
        try unit.allocateRenderResources()
        defer { unit.deallocateRenderResources() }
        unit.reset()

        let block: AVAudioFrameCount = 4096
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block),
              let aligned = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: block) else {
            throw OfflineMediaError.message("无法分配音频处理缓冲区。")
        }
        var outputSettings = format.settings
        outputSettings[AVLinearPCMIsNonInterleaved] = false
        let writer = try AVAudioFile(forWriting: destination, settings: outputSettings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        let latency = AVAudioFramePosition((unit.latency * format.sampleRate).rounded())
        let total = file.length + latency
        let render = unit.renderBlock
        var position: AVAudioFramePosition = 0
        var written: AVAudioFramePosition = 0
        var lastProgress = -1

        // The render callback only copies the current block. File IO stays outside it.
        let pull: AURenderPullInputBlock = { flags, time, count, _, list in
            guard Int(time.pointee.mSampleTime) == Int(position), count <= input.frameLength else {
                return kAudioUnitErr_CannotDoInCurrentContext
            }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard buffers.count == Int(format.channelCount) else { return kAudioUnitErr_FormatNotSupported }
            for channel in buffers.indices {
                let bytes = Int(count) * MemoryLayout<Float>.size
                if let data = buffers[channel].mData {
                    memcpy(data, input.floatChannelData![channel], bytes)
                } else {
                    buffers[channel].mData = UnsafeMutableRawPointer(input.floatChannelData![channel])
                }
                buffers[channel].mDataByteSize = UInt32(bytes)
            }
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            return noErr
        }
        while position < total {
            try Task.checkCancellation()
            try autoreleasepool {
                let count = AVAudioFrameCount(min(AVAudioFramePosition(block), total - position))
                input.frameLength = count
                for channel in 0 ..< Int(format.channelCount) {
                    input.floatChannelData![channel].initialize(repeating: 0, count: Int(count))
                }
                let available = AVAudioFrameCount(min(AVAudioFramePosition(count), max(0, file.length - position)))
                if available > 0 {
                    try file.read(into: input, frameCount: available)
                    guard input.frameLength == available else {
                        throw OfflineMediaError.message("源音频读取不完整，已停止输出。")
                    }
                }
                input.frameLength = count
                output.frameLength = count
                var time = AudioTimeStamp()
                time.mSampleTime = Double(position)
                time.mFlags = .sampleTimeValid
                var flags: AudioUnitRenderActionFlags = []
                let status = render(&flags, &time, count, 0, output.mutableAudioBufferList, pull)
                guard status == noErr else {
                    throw OfflineMediaError.message("效果器处理失败（\(status)）。")
                }
                // Flush the complete algorithmic delay, then remove it from the file.
                let skip = Int(max(0, min(AVAudioFramePosition(count), latency - position)))
                let keep = Int(count) - skip
                if keep > 0 {
                    aligned.frameLength = AVAudioFrameCount(keep)
                    for channel in 0 ..< Int(format.channelCount) {
                        memcpy(aligned.floatChannelData![channel], output.floatChannelData![channel] + skip,
                               keep * MemoryLayout<Float>.size)
                    }
                    try writer.write(from: aligned)
                    written += AVAudioFramePosition(keep)
                }
                position += AVAudioFramePosition(count)
                let percent = Int(Double(position) / Double(total) * 100)
                if percent != lastProgress {
                    lastProgress = percent
                    progress(Double(position) / Double(total), "正在处理音频")
                }
            }
        }
        guard written == file.length else { throw OfflineMediaError.message("处理后的音频长度校验失败。") }
    }

    nonisolated static func audioExtension(for source: URL) throws -> String {
        let file = try AVAudioFile(forReading: source)
        // Large files use CAF rather than overflowing a RIFF/WAV size field.
        return Double(file.length) * Double(file.processingFormat.channelCount) * 4 < Double(UInt32.max) - 4096
            ? "wav" : "caf"
    }

    /// The completed file is moved without replacement; even a concurrent name collision is safe.
    nonisolated static func publish(staging: URL, source: URL, effect: DayuEffectKind, extension suffix: String) throws -> URL {
        let parent = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent + "_" + effect.title
        for number in 1 ... 10_000 {
            try Task.checkCancellation()
            let name = stem + (number == 1 ? "" : "_\(number)") + "." + suffix
            let destination = parent.appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: staging, to: destination)
                return destination
            } catch {
                if FileManager.default.fileExists(atPath: destination.path) { continue }
                throw error
            }
        }
        throw OfflineMediaError.message("同名副本过多，请整理原目录后重试。")
    }
}

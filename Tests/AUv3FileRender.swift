import Foundation
import AVFoundation
import AudioToolbox

@main struct FileRender {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { fatalError("Usage: input.wav output.wav [type0or1] [quality0or1] [gainDb]") }
        let inputFile = try AVAudioFile(forReading: URL(fileURLWithPath: args[1]))
        guard inputFile.length < 2_000_000 else { fatalError("This diagnostic probe is limited to short samples; use the streaming renderer for long files") }
        let format = inputFile.processingFormat
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(inputFile.length))!
        try inputFile.read(into: input)
        let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: 0x64796372, componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
        let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
        let au = av.auAudioUnit
        try au.inputBusses[0].setFormat(format); try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        let tree = au.parameterTree!
        tree.parameter(withAddress: 2)!.value = args.count > 3 ? Float(args[3])! : 0
        tree.parameter(withAddress: 0)!.value = args.count > 4 ? Float(args[4])! : 0
        tree.parameter(withAddress: 3)!.value = args.count > 5 ? Float(args[5])! : 0
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        let latency = Int((au.latency * format.sampleRate).rounded())
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let writer = try AVAudioFile(forWriting: URL(fileURLWithPath: args[2]), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let aligned = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let sourceFrames = Int(input.frameLength)
        let pull: AURenderPullInputBlock = { flags, time, count, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            let start = Int(time.pointee.mSampleTime)
            for c in buffers.indices {
                let p = buffers[c].mData!.assumingMemoryBound(to: Float.self)
                for i in 0..<Int(count) { p[i] = start + i < sourceFrames ? input.floatChannelData![c][start + i] : 0 }
                buffers[c].mDataByteSize = count * 4
            }
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            return noErr
        }
        let render = au.renderBlock
        var written = 0
        for start in stride(from: 0, to: sourceFrames + latency, by: 512) {
            let count = min(512, sourceFrames + latency - start)
            output.frameLength = AUAudioFrameCount(count)
            var time = AudioTimeStamp(); time.mSampleTime = Double(start); time.mFlags = .sampleTimeValid
            var flags: AudioUnitRenderActionFlags = []
            guard render(&flags, &time, AUAudioFrameCount(count), 0, output.mutableAudioBufferList, pull) == noErr else { fatalError("AU render failed") }
            let skip = max(0, latency - start)
            if skip < count {
                aligned.frameLength = AUAudioFrameCount(count - skip)
                for c in 0..<Int(format.channelCount) {
                    for i in skip..<count { aligned.floatChannelData![c][i - skip] = output.floatChannelData![c][i] }
                }
                try writer.write(from: aligned); written += count - skip
            }
        }
        print("sourceFrames=\(sourceFrames) writtenFrames=\(written) latencyRemoved=\(latency) effect=\(au.fullState?["dayuEffectKind"] ?? "unknown")")
    }
}

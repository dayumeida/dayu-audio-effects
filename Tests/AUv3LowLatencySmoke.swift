import Foundation
import AVFoundation
import AudioToolbox

@main struct Smoke {
    static func main() async throws {
        let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: 0x64796c6c, componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
        let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
        let au = av.auAudioUnit
        print("latencyBeforeAllocation=\(au.latency)")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        try au.inputBusses[0].setFormat(format)
        try au.outputBusses[0].setFormat(format)
        au.maximumFramesToRender = 512
        guard let tree = au.parameterTree, tree.allParameters.count == 7 else { fatalError("parameter tree unavailable") }
        let target = tree.parameter(withAddress: 0)!
        target.value = -15
        let state = au.fullState
        target.value = -6
        au.fullState = state
        guard abs(target.value + 15) < 0.001 else { fatalError("state roundtrip failed") }
        target.value = -12
        try au.allocateRenderResources()
        defer { au.deallocateRenderResources() }
        print("instantiated \(au.componentDescription) parameters=\(tree.allParameters.count) latency=\(au.latency)")
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        let pull: AURenderPullInputBlock = { flags, time, count, _, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for channel in buffers.indices {
                guard let data = buffers[channel].mData?.assumingMemoryBound(to: Float.self) else { return kAudioUnitErr_InvalidPropertyValue }
                for i in 0..<Int(count) {
                    data[i] = 0.03 * sin(Float((time.pointee.mSampleTime + Double(i)) * 2 * .pi * 220 / 48000)) * (channel == 0 ? 1 : 0.5)
                }
                buffers[channel].mDataByteSize = count * 4
            }
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
            return noErr
        }
        let block = au.renderBlock
        var square: Double = 0, samples = 0, peak: Float = 0
        let total = Int(48000 * (au.latency + 3))
        let start = Int(48000 * (au.latency + 1))
        for sample in stride(from: 0, to: total, by: 512) {
            let frames = AUAudioFrameCount(min(512, total - sample))
            output.frameLength = frames
            var time = AudioTimeStamp(); time.mSampleTime = Double(sample); time.mFlags = .sampleTimeValid
            var flags: AudioUnitRenderActionFlags = []
            let status = block(&flags, &time, frames, 0, output.mutableAudioBufferList, pull)
            guard status == noErr else { fatalError("render status \(status)") }
            for i in 0..<Int(frames) {
                let value = output.floatChannelData![0][i]
                guard value.isFinite else { fatalError("non-finite output") }
                if sample + i >= start { square += Double(value * value); samples += 1; peak = max(peak, abs(value)) }
            }
        }
        guard samples > 0, peak > 0.0001 else { fatalError("no wet audio after declared latency") }
        print("renderedFrames=\(total) wetRMS=\(sqrt(square / Double(samples))) peak=\(peak) fullStateRoundtrip=PASS finiteAudio=PASS")
    }
}

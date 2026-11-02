import Foundation
import AVFoundation
import AudioToolbox

@main struct Smoke {
    static func main() async throws {
        for (subtype, tag, expectedLatency, expectedDefault) in [(UInt32(0x6479646e), "audio-denoise-ai", 30722.0 / 48000, Float(80))] {
            let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: subtype, componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
            let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
            let au = av.auAudioUnit
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            try au.inputBusses[0].setFormat(format)
            try au.outputBusses[0].setFormat(format)
            guard abs(au.latency - expectedLatency) < 1e-9, let tree = au.parameterTree, tree.allParameters.count == 7 else { fatalError("wrong component contract") }
            let target = tree.parameter(withAddress: 2)!
            guard target.value == expectedDefault else { fatalError("wrong core defaults") }
            guard au.fullState?["dayuEffectKind"] as? String == tag else { fatalError("stale extension or missing effect tag") }
            target.value = 45
            let saved = au.fullState!
            target.value = 50
            au.fullState = saved
            guard target.value == 45 else { fatalError("state did not restore") }
            var foreign = saved
            foreign["dayuEffectKind"] = "reference"
            target.value = 60
            au.fullState = foreign
            guard target.value == 60 else { fatalError("foreign effect state applied") }
            var legacy = saved
            legacy.removeValue(forKey: "dayuEffectKind")
            au.fullState = legacy
            guard target.value == 45 else { fatalError("legacy state broke") }
            target.value = expectedDefault
            guard tree.parameter(withAddress: 0) == nil, let analyzing = tree.parameter(withAddress: 7), !analyzing.flags.contains(.flag_IsWritable) else { fatalError("wrong denoise schema") }
            guard au.fullState?["dayuDenoiseParameters"] != nil, au.fullState?["dayuLevelerParameters"] == nil else { fatalError("wrong state schema") }
            au.maximumFramesToRender = 512
            try au.allocateRenderResources()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
            let pull: AURenderPullInputBlock = { flags, time, count, _, list in
                let buffers = UnsafeMutableAudioBufferListPointer(list)
                for c in buffers.indices {
                    let data = buffers[c].mData!.assumingMemoryBound(to: Float.self)
                    for i in 0..<Int(count) { data[i] = .init(0.03 * sin((time.pointee.mSampleTime + Double(i)) * 2 * .pi * 220 / 48000)) * (c == 0 ? 1 : 0.5) }
                    buffers[c].mDataByteSize = count * 4
                }
                flags.pointee.remove(.unitRenderAction_OutputIsSilence)
                return noErr
            }
            let render = au.renderBlock
            let total = Int(48000 * (expectedLatency + 2))
            var peak: Float = 0
            for start in stride(from: 0, to: total, by: 512) {
                let frames = AUAudioFrameCount(min(512, total - start))
                output.frameLength = frames
                var time = AudioTimeStamp(); time.mSampleTime = Double(start); time.mFlags = .sampleTimeValid
                var flags: AudioUnitRenderActionFlags = []
                guard render(&flags, &time, frames, 0, output.mutableAudioBufferList, pull) == noErr else { fatalError("render failed") }
                for i in 0..<Int(frames) {
                    let x = output.floatChannelData![0][i]
                    guard x.isFinite else { fatalError("non-finite audio") }
                    peak = max(peak, abs(x))
                }
            }
            guard peak > 0.0001 else { fatalError("no audio after latency") }
            au.deallocateRenderResources()
            print("\(tag): latency=\(expectedLatency) defaults=PASS taggedState=PASS legacyState=PASS foreignStateRejected=PASS outOfProcessAudio=PASS peak=\(peak)")
        }
    }
}

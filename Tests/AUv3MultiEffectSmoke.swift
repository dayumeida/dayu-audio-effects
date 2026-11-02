import Foundation
import AVFoundation
import AudioToolbox

private struct EffectCase {
    let subtype: UInt32, tag: String, key: String, identifier: String
    let count: Int, latencyFrames: Double
    let initial: Float, changed: Float, other: Float
}
@main struct Smoke {
    // The out-of-process parameter cache and document-state reply can arrive
    // on different XPC turns. Check both, with a bounded host-side wait.
    private static func waitForState(_ au: AUAudioUnit, _ item: EffectCase, _ parameter: AUParameter, _ expected: Float) async throws {
        for _ in 0..<100 {
            let values = au.fullState?[item.key] as? [String: NSNumber]
            if parameter.value == expected, values?[item.identifier]?.floatValue == expected { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("state failed to converge: \(item.tag) expected=\(expected) actual=\(parameter.value)")
    }
    static func main() async throws {
        let cases = [
            EffectCase(subtype: 0x64796c76, tag: "reference", key: "dayuLevelerParameters", identifier: "targetLevel", count: 7, latencyFrames: 362496, initial: -3, changed: -20, other: -21),
            EffectCase(subtype: 0x64796c6c, tag: "low-latency", key: "dayuLevelerParameters", identifier: "targetLevel", count: 7, latencyFrames: 240, initial: -3, changed: -20, other: -21),
            EffectCase(subtype: 0x6479646e, tag: "audio-denoise-ai", key: "dayuDenoiseParameters", identifier: "strength", count: 7, latencyFrames: 30722, initial: 80, changed: 45, other: 60),
            EffectCase(subtype: 0x64796372, tag: "era5-declipper", key: "dayuDeclipperParameters", identifier: "outputGain", count: 5, latencyFrames: 7871, initial: 0, changed: -8, other: -10)
        ]
        for item in cases {
            let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: item.subtype, componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
            let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
            let au = av.auAudioUnit
            let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
            try au.inputBusses[0].setFormat(format)
            try au.outputBusses[0].setFormat(format)
            let latency = item.latencyFrames / 48000
            guard abs(au.latency - latency) < 1e-9, let tree = au.parameterTree, tree.allParameters.count == item.count,
                  let parameter = tree.allParameters.first(where: { $0.identifier == item.identifier }), parameter.value == item.initial else { fatalError("wrong component contract: \(item.tag)") }
            guard au.fullState?["dayuEffectKind"] as? String == item.tag, au.fullState?[item.key] != nil else { fatalError("stale extension or wrong state schema") }
            if item.tag == "audio-denoise-ai" {
                guard tree.parameter(withAddress: 0) == nil, let status = tree.parameter(withAddress: 7), !status.flags.contains(.flag_IsWritable) else { fatalError("wrong denoise read-only parameter schema") }
            }
            parameter.value = item.changed
            try await waitForState(au, item, parameter, item.changed)
            let saved = au.fullStateForDocument!
            parameter.value = item.other
            try await waitForState(au, item, parameter, item.other)
            au.fullStateForDocument = saved
            try await waitForState(au, item, parameter, item.changed)
            var foreign = saved; foreign["dayuEffectKind"] = "foreign-effect"
            parameter.value = item.other
            try await waitForState(au, item, parameter, item.other)
            au.fullState = foreign
            try await Task.sleep(nanoseconds: 30_000_000)
            guard parameter.value == item.other else { fatalError("foreign effect state applied") }
            try await waitForState(au, item, parameter, item.other)
            var legacy = saved; legacy.removeValue(forKey: "dayuEffectKind")
            au.fullState = legacy
            try await waitForState(au, item, parameter, item.changed)
            parameter.value = item.initial
            try await waitForState(au, item, parameter, item.initial)
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
            let total = Int(48000 * (latency + 2))
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
            print("\(item.tag): parameters=\(item.count) latencyFrames=\(item.latencyFrames) defaults=PASS documentState=PASS foreignStateRejected=PASS outOfProcessAudio=PASS peak=\(peak)")
        }
    }
}

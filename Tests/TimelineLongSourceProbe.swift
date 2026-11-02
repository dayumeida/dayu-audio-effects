import AVFoundation
import Foundation

@main struct TimelineLongSourceProbe {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("LONG SOURCE PROBE: \(error)\n", stderr); exit(1) }
    }
    @MainActor static func run() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let preset = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))) as! [String: Any]
        let desc = AudioComponentDescription(componentType: 0x61756678, componentSubType: 0x64796c76, componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
        let av = try await AVAudioUnit.instantiate(with: desc, options: .loadOutOfProcess)
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        engine.attach(player); engine.attach(av)
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        engine.connect(player, to: av, format: format); engine.connect(av, to: engine.mainMixerNode, format: format)
        engine.prepare()
        for param in av.auAudioUnit.parameterTree!.allParameters {
            if let value = (preset["parameters"] as? [String: NSNumber])?[param.identifier] { param.value = value.floatValue }
        }
        let preview = MediaPreviewModel()
        preview.updateSettings(OfflineEffectSettings(kind: .referenceLeveler, unit: av.auAudioUnit))
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                preview.updateSettings(OfflineEffectSettings(kind: .referenceLeveler, unit: av.auAudioUnit))
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watcher.cancel(); preview.clear(); engine.stop() }
        preview.load(source: source)
        try await wait(preview, name: "initial")
        print("initial ready")
        preview.seek(to: 396.464920635, autoplay: false)
        for _ in 0 ..< 7 { preview.zoom(factor: 2) }
        try await wait(preview, name: "seek")
        print("seek ready at \(preview.playheadTime), regions=\(preview.processedRegions.count)")
        withExtendedLifetime(av) {}
    }
    @MainActor static func wait(_ model: MediaPreviewModel, name: String) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !model.isReady {
            if let error = model.error { throw OfflineMediaError.message(error) }
            if Date() > deadline {
                throw OfflineMediaError.message("\(name): \(model.status), preparing=\(model.isPreparing), rendering=\(model.isRendering)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

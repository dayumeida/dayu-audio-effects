import AVFoundation
import Foundation

/// Runs the exact production import/render/remux path on disposable fixtures.
@main struct OfflineMediaProcessingTests {
    @MainActor static func main() async {
        do { try await run() }
        catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor static func run() async throws {
        let args = CommandLine.arguments
        if args.count >= 3, args[1] == "inspect" {
            try await inspect(URL(fileURLWithPath: args[2]))
            return
        }
        guard args.count >= 3, let kind = DayuEffectKind(rawValue: args[1]) else {
            fatalError("Usage: OfflineMediaProcessingTests effect source [bypass|cancel]")
        }
        let source = URL(fileURLWithPath: args[2])
        let description = AudioComponentDescription(componentType: 0x61756678, componentSubType: kind.subtype,
            componentManufacturer: 0x44617975, componentFlags: 0, componentFlagsMask: 0)
        let av = try await AVAudioUnit.instantiate(with: description, options: .loadOutOfProcess)
        let unit = av.auAudioUnit
        unit.shouldBypassEffect = args.count > 3 && args[3] == "bypass"
        if args.count > 3 && args[3] == "gain" {
            unit.parameterTree?.allParameters.first(where: { $0.identifier == "outputGain" })?.value = -6
        }
        let settings = OfflineEffectSettings(kind: kind, unit: unit)
        let cancellation = CancellationHandle()
        let worker = Task.detached {
            try await OfflineMediaProcessor.process(source: source, settings: settings) { value, _ in
                if args.count > 3 && args[3] == "cancel-mid" && value > 0.03 { cancellation.cancel() }
            }
        }
        cancellation.set(worker)
        if args.count > 3 && args[3] == "cancel" { worker.cancel() }
        do {
            let output = try await worker.value
            print(output.path)
        } catch is CancellationError {
            print("CANCELLED")
        }
        withExtendedLifetime(av) {}
    }

    static func inspect(_ url: URL) async throws {
        let asset = AVURLAsset(url: url)
        var result: [[String: Any]] = []
        for track in try await asset.loadTracks(withMediaType: .audio) {
            let description = try await track.load(.formatDescriptions).first!
            let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)!.pointee
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { throw reader.error! }
            var start = Double.infinity, end = -Double.infinity
            while let sample = output.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) == 0 { continue }
                let pts = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
                let duration = CMSampleBufferGetOutputDuration(sample).seconds
                start = min(start, pts); end = max(end, pts + duration)
            }
            guard reader.status == .completed else { throw reader.error! }
            result.append(["start": start, "end": end, "rate": asbd.mSampleRate,
                           "frames": Int(((end - start) * asbd.mSampleRate).rounded())])
        }
        print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
    }
}

private final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<URL, Error>?
    func set(_ task: Task<URL, Error>) { lock.lock(); self.task = task; lock.unlock() }
    func cancel() { lock.lock(); let task = task; lock.unlock(); task?.cancel() }
}

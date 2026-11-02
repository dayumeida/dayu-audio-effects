import AVFoundation

public final class _______ExtensionAudioUnit: AUAudioUnit, @unchecked Sendable {
    let effectKind: DayuEffectKind
    public var isLowLatencyMode: Bool { effectKind == .realtimeLeveler }
    private let processHelper: AUProcessHelper
    private let inputBus: AUAudioUnitBus
    private let outputBus: AUAudioUnitBus
    private var _inputBusses: AUAudioUnitBusArray!
    private var _outputBusses: AUAudioUnitBusArray!

    @objc override init(componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions) throws {
        guard componentDescription.componentType == 0x61756678,
              componentDescription.componentManufacturer == 0x44617975,
              let kind = DayuEffectKind(subtype: componentDescription.componentSubType),
              let helper = AUProcessHelper.createForSubtype(kind.subtype) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_InvalidPropertyValue),
                          userInfo: [NSLocalizedDescriptionKey: "不支持的音频效果类型。"])
        }
        effectKind = kind
        processHelper = helper
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        inputBus = try AUAudioUnitBus(format: format)
        outputBus = try AUAudioUnitBus(format: format)
        try super.init(componentDescription: componentDescription, options: options)
        inputBus.maximumChannelCount = 2
        outputBus.maximumChannelCount = 2
        _inputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
        _outputBusses = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])
        setupParameterTree(dayuParameterSpecs(for: effectKind, defaults: defaultParameterValues).createAUParameterTree())
    }

    deinit { AUProcessHelper.destroy(processHelper) }
    public override var inputBusses: AUAudioUnitBusArray { _inputBusses }
    public override var outputBusses: AUAudioUnitBusArray { _outputBusses }
    public override var channelCapabilities: [NSNumber]? { [1, 1, 2, 2] }
    public override var canProcessInPlace: Bool { true }
    public override var latency: TimeInterval { processHelper.latencySecondsForRate(outputBus.format.sampleRate) }
    public override var tailTime: TimeInterval { latency }
    public override var supportsUserPresets: Bool { true }

    public override var maximumFramesToRender: AUAudioFrameCount {
        get { processHelper.maximumFramesToRender() }
        set { processHelper.setMaximumFramesToRender(newValue) }
    }
    public override var shouldBypassEffect: Bool {
        get { processHelper.isBypassed() }
        set { processHelper.setBypass(newValue) }
    }
    public override var internalRenderBlock: AUInternalRenderBlock {
        processHelper.internalRenderBlock()
    }
    public override func shouldChange(to format: AVAudioFormat, for bus: AUAudioUnitBus) -> Bool {
        // Reject unsupported formats during negotiation, before a host accepts
        // them and later discovers that resources cannot be allocated.
        super.shouldChange(to: format, for: bus) &&
            format.sampleRate.isFinite && format.sampleRate >= effectKind.minimumSampleRate &&
            format.sampleRate <= 384_000 && (1 ... 2).contains(format.channelCount) &&
            format.commonFormat == .pcmFormatFloat32 && !format.isInterleaved
    }
    public override func allocateRenderResources() throws {
        let input = inputBus.format, output = outputBus.format
        guard input.channelCount == output.channelCount,
              (1 ... 2).contains(input.channelCount),
              input.sampleRate == output.sampleRate,
              input.sampleRate.isFinite, input.sampleRate >= effectKind.minimumSampleRate, input.sampleRate <= 384_000,
              input.commonFormat == .pcmFormatFloat32, output.commonFormat == .pcmFormatFloat32,
              !input.isInterleaved, !output.isInterleaved else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let modelPath = Bundle(for: Self.self).url(forResource: "dayu-denoise-weights", withExtension: "bin")?.path
        let resourcesReady = (modelPath ?? "").withCString { processHelper.configureResources($0) }
        guard resourcesReady, processHelper.allocate(output.sampleRate, output.channelCount, maximumFramesToRender) else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(kAudioUnitErr_FailedInitialization))
        }
        do { try super.allocateRenderResources() }
        catch { processHelper.deallocate(); throw error }
    }
    public override func deallocateRenderResources() {
        processHelper.deallocate()
        super.deallocateRenderResources()
    }
    public override func reset() {
        super.reset()
        processHelper.reset()
    }

    public var hasReceivedAudio: Bool { processHelper.hasReceivedAudio() }
    public var warmupRemainingSeconds: Double { processHelper.warmupRemainingSeconds() }
    public var defaultParameterValues: [Float] {
        (0 ..< processHelper.parameterCount()).map { processHelper.defaultParameter($0) }
    }

    public func meter(_ index: UInt32) -> Float { processHelper.getMeter(index) }
    public func waveformPoint(_ stream: UInt32, _ index: UInt32) -> Float { processHelper.getWaveformPoint(stream, index) }

    public func setupParameterTree(_ tree: AUParameterTree) {
        parameterTree = tree
        for parameter in tree.allParameters { processHelper.setParameter(parameter.address, parameter.value) }
        tree.implementorValueObserver = { [weak self] parameter, value in
            self?.processHelper.setParameter(parameter.address, value)
        }
        tree.implementorValueProvider = { [weak self] parameter in
            self?.processHelper.getParameter(parameter.address) ?? parameter.minValue
        }
        tree.implementorStringFromValueCallback = { parameter, value in
            let number = value?.pointee ?? parameter.value
            switch parameter.unit {
            case .milliseconds: return String(format: "%.0f ms", number)
            case .percent: return String(format: "%.0f %%", number)
            case .boolean: return number >= 0.5 ? "开启" : "关闭"
            case .indexed:
                let index = Int(number.rounded())
                if let values = parameter.valueStrings, values.indices.contains(index) { return values[index] }
                return String(format: "%.0f", number)
            case .decibels: return String(format: "%.1f dB", number)
            default: return String(format: "%.2f", number)
            }
        }
    }

    public override var fullState: [String: Any]? {
        get {
            var state = super.fullState ?? [:]
            var values: [String: NSNumber] = [:]
            for parameter in parameterTree?.allParameters ?? [] {
                values[parameter.identifier] = NSNumber(value: processHelper.getParameter(parameter.address))
            }
            state["dayuEffectKind"] = effectKind.rawValue
            state[effectKind.stateParameterKey] = values
            return state
        }
        set {
            // Legacy documents lack an effect tag; retain their original interpretation.
            // Tagged documents must never transfer parameters into another effect.
            if let tag = newValue?["dayuEffectKind"] as? String, tag != effectKind.rawValue { return }
            super.fullState = newValue
            guard let values = newValue?[effectKind.stateParameterKey] as? [String: NSNumber] else { return }
            for parameter in parameterTree?.allParameters ?? [] {
                if parameter.flags.contains(.flag_IsWritable), let number = values[parameter.identifier], number.floatValue.isFinite {
                    parameter.value = min(parameter.maxValue, max(parameter.minValue, number.floatValue))
                }
            }
        }
    }
    public override var fullStateForDocument: [String: Any]? {
        get { fullState }
        set { fullState = newValue }
    }
}

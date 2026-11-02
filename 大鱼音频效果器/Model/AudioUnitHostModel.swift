import SwiftUI
import AudioToolbox
import AVFAudio

@MainActor
@Observable
class AudioUnitHostModel {
    private let playEngine = SimplePlayEngine()
    var viewModel = AudioUnitViewModel()
    let offlineProcessing = OfflineProcessingModel()
    let mediaPreview = MediaPreviewModel()
    private(set) var selectedEffect: DayuEffectKind = .realtimeLeveler
    private(set) var isLoading = false
    private var loadTask: Task<Void, Never>?
    private var parameterWatch: Task<Void, Never>?
    private var savedStates: [DayuEffectKind: [String: Any]] = [:]
    private var loadGeneration = 0
    private var fileError: String?
    var audioUnitCrashed = false
    var validationResult: AudioComponentValidationResult?
    var currentValidationData: String?

    var isPlaying: Bool { mediaPreview.isPlaying || mediaPreview.isWaitingToPlay }
    var audioFileName: String { mediaPreview.source?.lastPathComponent ?? "尚未导入素材" }
    var audioFileError: String? { fileError ?? playEngine.playbackError }
    var auValString: String { "aufx \(selectedEffect.subtypeString) Dayu" }
    let wantsAudio = true
    let wantsMIDI = false
    let isFreeRunning = false
    private var invalidationObserver: NSObjectProtocol?
    var canExport: Bool { !isLoading && !audioUnitCrashed && !offlineProcessing.isProcessing && mediaPreview.isReady && !offlineProcessing.jobs.isEmpty }

    init() {
        invalidationObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name(String(kAudioComponentInstanceInvalidationNotification)),
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let unit = notification.object as? AUAudioUnit else { return }
            Task { @MainActor [weak self] in
                guard let self, self.playEngine.avAudioUnit?.auAudioUnit === unit else { return }
                self.audioUnitCrashed = true
            }
        }
        loadEffect(.realtimeLeveler)
    }

    func selectEffect(_ kind: DayuEffectKind) {
        guard !offlineProcessing.isProcessing else { return }
        guard kind != selectedEffect || audioUnitCrashed || viewModel.viewController == nil else { return }
        if let state = playEngine.avAudioUnit?.auAudioUnit.fullState { savedStates[selectedEffect] = state }
        loadEffect(kind)
    }

    private func loadEffect(_ kind: DayuEffectKind) {
        loadTask?.cancel()
        parameterWatch?.cancel()
        mediaPreview.updateSettings(nil)
        loadGeneration += 1
        let generation = loadGeneration
        playEngine.stopPlaying()
        playEngine.reset()
        selectedEffect = kind
        audioUnitCrashed = false
        isLoading = true
        viewModel = AudioUnitViewModel(title: kind.title, message: "正在加载音频插件…")
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            let controller = await self.playEngine.initComponent(type: "aufx", subType: kind.subtypeString, manufacturer: "Dayu")
            guard !Task.isCancelled, self.loadGeneration == generation else { return }
            if let state = self.savedStates[kind] { self.playEngine.avAudioUnit?.auAudioUnit.fullState = state }
            self.viewModel = AudioUnitViewModel(showAudioControls: true, title: kind.title,
                message: controller == nil ? (self.playEngine.playbackError ?? "插件界面无法加载。请重新选择效果器。") : "插件已加载",
                viewController: controller)
            self.isLoading = false
            self.parameterWatch = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self, self.loadGeneration == generation,
                          let unit = self.playEngine.avAudioUnit?.auAudioUnit else { return }
                    self.mediaPreview.setExporting(self.offlineProcessing.isProcessing)
                    self.mediaPreview.updateSettings(OfflineEffectSettings(kind: kind, unit: unit))
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
        }
    }

    func loadAudioFile(_ url: URL) {
        importMedia([url])
    }
    func importMedia(_ urls: [URL]) {
        guard !offlineProcessing.isProcessing else { return }
        playEngine.stopPlaying()
        if let source = offlineProcessing.stage(urls) { mediaPreview.load(source: source) }
    }

    func selectMedia(_ url: URL) {
        guard !offlineProcessing.isProcessing, mediaPreview.source != url else { return }
        mediaPreview.load(source: url)
    }

    func clearMedia() {
        guard !offlineProcessing.isProcessing else { return }
        mediaPreview.clear()
        offlineProcessing.clear()
    }

    func removeMedia(_ job: OfflineMediaJob) {
        guard !offlineProcessing.isProcessing else { return }
        let selected = mediaPreview.source == job.source
        offlineProcessing.remove(job.id)
        if selected {
            if let first = offlineProcessing.jobs.first { mediaPreview.load(source: first.source) }
            else { mediaPreview.clear() }
        }
    }

    func exportMedia() {
        guard !isLoading, !audioUnitCrashed, let unit = playEngine.avAudioUnit?.auAudioUnit else {
            offlineProcessing.error = "请等待效果器加载完成。"
            return
        }
        let settings = OfflineEffectSettings(kind: selectedEffect, unit: unit)
        // Read parameters again at the click: a knob can change between watcher ticks.
        mediaPreview.updateSettings(settings)
        guard canExport else { return }
        playEngine.stopPlaying()
        mediaPreview.setExporting(true)
        offlineProcessing.begin(settings: settings)
    }
    func startPlaying() { guard !isLoading, !offlineProcessing.isProcessing else { return }; mediaPreview.play(.processed) }
    func stopPlaying() { playEngine.stopPlaying(); mediaPreview.stopPlayback() }
}

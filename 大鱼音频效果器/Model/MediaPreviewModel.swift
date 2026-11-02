import AVFoundation
import Observation
import OSLog

nonisolated private let previewTrace = Logger(subsystem: "media.dayu.audio.leveler", category: "timeline-preview")

nonisolated enum PreviewPlaybackVersion: Sendable { case original, processed }

nonisolated private struct TimelinePlaybackBuffer: Sendable {
    let input: PreparedMediaPreview
    let rendered: RenderedMediaPreview?
}

@MainActor @Observable
final class MediaPreviewModel {
    private(set) var source: URL?
    private(set) var info: PreviewMediaInfo?
    private(set) var input: PreparedMediaPreview?
    private(set) var rendered: RenderedMediaPreview?
    private(set) var settings: OfflineEffectSettings?
    private(set) var isPreparing = false
    private(set) var isRendering = false
    private(set) var isExporting = false
    private(set) var requestedStart = 0.0
    private(set) var selectedTrackID: CMPersistentTrackID?
    private(set) var playingVersion: PreviewPlaybackVersion?
    private(set) var preferredVersion: PreviewPlaybackVersion = .processed
    private(set) var playbackPosition = 0.0
    private(set) var playheadTime = 0.0
    private(set) var viewport = AudioTimelineViewport()
    private(set) var overview: TimelineWaveformIndex?
    private(set) var overviewProgress = 0.0
    private(set) var isOverviewLoading = false
    private(set) var originalRegions: [TimelineWaveformRegion] = []
    private(set) var processedRegions: [TimelineWaveformRegion] = []
    var followsPlayhead = true
    var error: String?
    private var generation = 0
    private var renderGeneration = 0
    private var overviewGeneration = 0
    private var prefetchGeneration = 0
    private var prepareTask: Task<Void, Never>?
    private var prepareWorker: Task<PreparedMediaPreview, Error>?
    private var renderWorker: Task<RenderedMediaPreview, Error>?
    private var overviewTask: Task<Void, Never>?
    private var overviewWorker: Task<TimelineWaveformIndex, Error>?
    private var overviewSource: URL?
    private var overviewTrack: CMPersistentTrackID?
    private var player: AVAudioPlayer?
    private var playbackTask: Task<Void, Never>?
    private var pendingPlayback: (time: Double, version: PreviewPlaybackVersion)?
    private var prefetchTask: Task<Void, Never>?
    private var prefetchWorker: Task<TimelinePlaybackBuffer, Error>?
    private var prefetched: TimelinePlaybackBuffer?
    private var nextPlayer: AVAudioPlayer?
    private var nextWasScheduled = false
    private var playbackGraceUntil = Date.distantPast

    var isPlaying: Bool { playingVersion != nil }
    var isWaitingToPlay: Bool { pendingPlayback != nil }
    var isReady: Bool {
        guard let input, let rendered, let settings else { return false }
        return !isPreparing && !isRendering && rendered.inputID == input.id && rendered.settings == settings
    }
    var maximumStart: Double { max(0, (info?.duration ?? 0) - 12) }
    var status: String {
        if isPreparing { return pendingPlayback == nil ? "正在准备所选位置的音频…" : "正在定位播放位置…" }
        if isRendering { return pendingPlayback == nil ? "正在按当前参数更新处理预览…" : "正在准备该位置的效果试听…" }
        if error != nil { return "预览未完成" }
        if isReady { return "可点击波形定位试听 · 确认后输出副本" }
        return source == nil ? "先导入素材，再调参预览" : "等待效果器加载"
    }

    func load(source: URL) {
        guard !isExporting else { return }
        stopPlayback()
        resetOverview()
        originalRegions = []; processedRegions = []
        viewport.reset(duration: 0)
        playheadTime = 0
        prepare(source: source, knownInfo: nil, trackID: nil, start: 0)
    }

    func setStart(_ seconds: Double) {
        guard let source, let info, !isExporting else { return }
        stopPlayback()
        playheadTime = min(maximumStart, max(0, seconds))
        prepare(source: source, knownInfo: info, trackID: selectedTrackID, start: playheadTime)
    }

    func selectTrack(_ id: CMPersistentTrackID) {
        guard let source, let info, !isExporting, selectedTrackID != id else { return }
        stopPlayback()
        resetOverview()
        originalRegions = []; processedRegions = []
        prepare(source: source, knownInfo: info, trackID: id, start: playheadTime)
    }

    func zoom(factor: Double, anchor: Double? = nil) {
        let focus = anchor ?? (playheadTime >= viewport.start && playheadTime <= viewport.end ? playheadTime : viewport.start + viewport.span / 2)
        viewport.zoom(factor: factor, anchor: focus)
    }
    func fitTimeline() { viewport.fit() }
    func panTimeline(by seconds: Double) { followsPlayhead = false; viewport.pan(by: seconds) }
    func scrollTimeline(to seconds: Double) { followsPlayhead = false; viewport.scroll(to: seconds) }
    func revealPlayhead() { viewport.reveal(playheadTime) }
    func scrub(to seconds: Double) {
        guard !isExporting, let info else { return }
        stopPlayback()
        playheadTime = min(info.duration, max(0, seconds))
    }

    /// Clicks use absolute source seconds, including clicks outside the rendered
    /// excerpt. Only the last seek request may start playback when rendering ends.
    func seek(to seconds: Double, version: PreviewPlaybackVersion? = nil, autoplay: Bool = true) {
        guard !isExporting, let source, let info else { return }
        let target = min(max(0, info.duration - 0.001), max(0, seconds))
        let version = version ?? preferredVersion
        haltPlayback()
        preferredVersion = version
        playheadTime = target
        pendingPlayback = autoplay ? (target, version) : nil
        if let input, contains(input, time: target) {
            playbackPosition = target - input.start
            if version == .original || isReady { fulfillPlaybackRequest() }
            else if !isRendering { scheduleRender(delay: .zero) }
        } else {
            prepare(source: source, knownInfo: info, trackID: selectedTrackID, start: target)
        }
    }

    func updateSettings(_ newSettings: OfflineEffectSettings?) {
        guard settings != newSettings else { return }
        let resume = playingVersion == .processed ? (playheadTime, PreviewPlaybackVersion.processed) : pendingPlayback
        settings = newSettings
        cancelRender()
        cancelPrefetch()
        processedRegions = []
        if playingVersion == .processed { haltPlayback() }
        pendingPlayback = resume
        if !isExporting { scheduleRender() }
    }

    func setExporting(_ value: Bool) {
        guard value != isExporting else { return }
        isExporting = value
        if value { stopPlayback(); cancelRender() }
        else if !isReady { scheduleRender() }
    }

    func refresh() {
        guard !isExporting else { return }
        if input != nil { cancelRender(); scheduleRender(delay: .zero) }
        else if let source { prepare(source: source, knownInfo: info, trackID: selectedTrackID, start: playheadTime) }
    }

    func clear() {
        guard !isExporting else { return }
        generation += 1
        prepareTask?.cancel(); prepareWorker?.cancel()
        cancelRender(); stopPlayback(); resetOverview(); removeInput()
        source = nil; info = nil
        requestedStart = 0; playheadTime = 0; playbackPosition = 0
        selectedTrackID = nil; isPreparing = false; error = nil
        viewport.reset(duration: 0)
        originalRegions = []; processedRegions = []
    }

    func play(_ version: PreviewPlaybackVersion) {
        guard !isExporting, let info else { return }
        if playingVersion == version || pendingPlayback?.version == version { stopPlayback(); return }
        let time = playheadTime >= info.duration - 0.001 ? 0 : playheadTime
        seek(to: time, version: version)
    }

    func stopPlayback() {
        if let player, let input, playingVersion != nil {
            playheadTime = min(info?.duration ?? .greatestFiniteMagnitude, input.start + player.currentTime)
        }
        pendingPlayback = nil
        haltPlayback()
    }

    private func haltPlayback() {
        playbackTask?.cancel(); playbackTask = nil
        player?.stop(); player = nil; playingVersion = nil
        cancelPrefetch()
    }

    private func contains(_ input: PreparedMediaPreview, time: Double) -> Bool {
        time >= input.start - 0.00001 && time < input.start + input.duration - 0.00001
    }

    private func fulfillPlaybackRequest() {
        guard let request = pendingPlayback, let input, !isExporting else { return }
        guard contains(input, time: request.time) else {
            if !isPreparing, let source, let info {
                prepare(source: source, knownInfo: info, trackID: selectedTrackID, start: request.time)
            }
            return
        }
        guard request.version == .original || isReady else { return }
        pendingPlayback = nil
        startPlayback(request.version, at: request.time)
    }

    private func startPlayback(_ version: PreviewPlaybackVersion, at time: Double) {
        guard let input, version == .original || isReady else { return }
        let url = version == .original ? input.originalURL : rendered!.url
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.currentTime = min(max(0, time - input.start), max(0, player.duration - 0.001))
            guard player.play() else { throw OfflineMediaError.message("无法开始试听。") }
            self.player = player
            playbackGraceUntil = Date().addingTimeInterval(0.3)
            playingVersion = version; preferredVersion = version
            playbackPosition = player.currentTime
            playheadTime = input.start + playbackPosition
            startPlaybackClock()
            prefetchNext()
        } catch { self.error = error.localizedDescription }
    }

    private func startPlaybackClock() {
        playbackTask?.cancel()
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let player = self.player, let input = self.input, let version = self.playingVersion else { return }
                if player.isPlaying {
                    self.playbackPosition = player.currentTime
                    self.playheadTime = min(self.info?.duration ?? .greatestFiniteMagnitude, input.start + player.currentTime)
                    if self.followsPlayhead { self.viewport.reveal(self.playheadTime) }
                } else {
                    if Date() < self.playbackGraceUntil {
                        try? await Task.sleep(for: .milliseconds(15))
                        continue
                    }
                    let nextTime = input.start + input.duration
                    if self.promotePrefetched(version: version, at: nextTime) { continue }
                    if let info = self.info, nextTime < info.duration - 0.001 {
                        self.seek(to: nextTime, version: version)
                    } else {
                        self.playheadTime = self.info?.duration ?? nextTime
                        self.pendingPlayback = nil
                        self.haltPlayback()
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func prefetchNext() {
        guard prefetched == nil, prefetchTask == nil, let input, let info, let settings,
              let version = playingVersion, !isExporting else { return }
        let nextTime = input.start + input.duration
        guard nextTime < info.duration - 0.001 else { return }
        let generation = prefetchGeneration
        prefetchTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let prepared = try await MediaPreviewRenderer.prepare(info: info, trackID: input.trackID, start: nextTime)
                do {
                    let rendered = version == .processed ? try await MediaPreviewRenderer.render(input: prepared, settings: settings) : nil
                    try Task.checkCancellation()
                    return TimelinePlaybackBuffer(input: prepared, rendered: rendered)
                } catch { try? FileManager.default.removeItem(at: prepared.directory); throw error }
            }
            guard let self else { worker.cancel(); return }
            self.prefetchWorker = worker
            do {
                let buffer = try await worker.value
                guard !Task.isCancelled, self.prefetchGeneration == generation, self.input?.id == input.id,
                      self.settings == settings, self.playingVersion == version else {
                    try? FileManager.default.removeItem(at: buffer.input.directory)
                    return
                }
                self.prefetched = buffer
                self.rememberOriginal(buffer.input)
                if let rendered = buffer.rendered { self.rememberProcessed(buffer.input, rendered: rendered) }
                let url = version == .original ? buffer.input.originalURL : buffer.rendered!.url
                let nextPlayer = try AVAudioPlayer(contentsOf: url)
                nextPlayer.prepareToPlay()
                nextPlayer.currentTime = max(0, nextTime - buffer.input.start)
                if let current = self.player, current.isPlaying {
                    let remaining = current.duration - current.currentTime
                    self.nextWasScheduled = remaining > 0.02 && nextPlayer.play(atTime: current.deviceCurrentTime + remaining)
                }
                self.nextPlayer = nextPlayer
                self.prefetchWorker = nil
            } catch {
                guard !Task.isCancelled, self.prefetchGeneration == generation else { return }
                // Playback falls back to an on-demand seek if prefetch cannot finish.
                self.prefetchWorker = nil
                self.prefetchTask = nil
            }
        }
    }

    private func promotePrefetched(version: PreviewPlaybackVersion, at time: Double) -> Bool {
        guard let buffer = prefetched, let next = nextPlayer, contains(buffer.input, time: time),
              version == .original || buffer.rendered?.settings == settings else { return false }
        let wasScheduled = nextWasScheduled
        prefetched = nil; nextPlayer = nil; nextWasScheduled = false
        prefetchTask = nil; prefetchWorker = nil
        player?.stop()
        removeInput()
        input = buffer.input; rendered = buffer.rendered
        requestedStart = buffer.input.start
        player = next
        playbackGraceUntil = Date().addingTimeInterval(0.3)
        playingVersion = version
        if !wasScheduled { next.currentTime = max(0, time - buffer.input.start); _ = next.play() }
        playheadTime = time; playbackPosition = max(0, time - buffer.input.start)
        if rendered == nil { scheduleRender(delay: .zero) }
        prefetchNext()
        return true
    }

    private func cancelPrefetch() {
        prefetchGeneration += 1
        prefetchTask?.cancel(); prefetchWorker?.cancel()
        prefetchTask = nil; prefetchWorker = nil
        nextPlayer?.stop(); nextPlayer = nil; nextWasScheduled = false
        if let prefetched { try? FileManager.default.removeItem(at: prefetched.input.directory) }
        prefetched = nil
    }

    private func prepare(source: URL, knownInfo: PreviewMediaInfo?, trackID: CMPersistentTrackID?, start: Double) {
        generation += 1
        let generation = generation
        prepareTask?.cancel(); prepareWorker?.cancel()
        cancelRender(); haltPlayback(); removeInput()
        self.source = source; info = knownInfo
        selectedTrackID = trackID; requestedStart = start
        error = nil; isPreparing = true
        prepareTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                let info: PreviewMediaInfo
                if let knownInfo { info = knownInfo }
                else { info = try await MediaPreviewRenderer.inspect(source: source) }
                try Task.checkCancellation()
                return try await MediaPreviewRenderer.prepare(info: info, trackID: trackID ?? info.tracks[0].id, start: start)
            }
            guard let self else { worker.cancel(); return }
            self.prepareWorker = worker
            do {
                let prepared = try await worker.value
                guard !Task.isCancelled, self.generation == generation else {
                    try? FileManager.default.removeItem(at: prepared.directory); return
                }
                self.input = prepared; self.info = prepared.info
                self.requestedStart = prepared.start; self.selectedTrackID = prepared.trackID
                self.isPreparing = false; self.prepareWorker = nil
                if self.viewport.total != prepared.info.duration { self.viewport.reset(duration: prepared.info.duration) }
                self.rememberOriginal(prepared)
                self.startOverview(info: prepared.info, trackID: prepared.trackID)
                self.fulfillPlaybackRequest()
                self.scheduleRender(delay: .zero)
            } catch {
                guard !Task.isCancelled, self.generation == generation else { return }
                self.isPreparing = false; self.prepareWorker = nil
                self.pendingPlayback = nil
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }

    private func scheduleRender(delay: Duration = .milliseconds(450)) {
        guard let input, let settings, !isPreparing, !isExporting else { return }
        renderGeneration += 1
        let generation = renderGeneration
        isRendering = true; error = nil
        previewTrace.debug("render queued generation \(generation), start \(input.start)")
        // Completion belongs to the detached render itself. Cancelling a UI or
        // preparation task must not strand the latest preview in a busy state.
        renderWorker = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                let result = try await MediaPreviewRenderer.render(input: input, settings: settings)
                try Task.checkCancellation()
                let accepted = await self?.acceptRender(result, inputID: input.id, generation: generation)
                if accepted != true { try? FileManager.default.removeItem(at: result.url) }
                return result
            } catch {
                await self?.renderFailed(message: error.localizedDescription,
                    cancelled: error is CancellationError || Task.isCancelled, generation: generation)
                throw error
            }
        }
    }

    private func acceptRender(_ result: RenderedMediaPreview, inputID: UUID, generation: Int) -> Bool {
        guard renderGeneration == generation, let input, input.id == inputID,
              settings == result.settings, !isExporting else { return false }
        if let old = rendered { try? FileManager.default.removeItem(at: old.url) }
        rendered = result
        isRendering = false; renderWorker = nil
        rememberProcessed(input, rendered: result)
        fulfillPlaybackRequest()
        prefetchNext()
        previewTrace.debug("render accepted generation \(generation)")
        return true
    }

    private func renderFailed(message: String, cancelled: Bool, generation: Int) {
        guard renderGeneration == generation else { return }
        isRendering = false; renderWorker = nil; pendingPlayback = nil
        error = cancelled ? "预览已中断，请点击更新效果重试。" : message
        previewTrace.debug("render failed generation \(generation): \(message, privacy: .public)")
    }

    private func rememberOriginal(_ input: PreparedMediaPreview) {
        originalRegions.removeAll { abs($0.start - input.start) < 0.0001 }
        originalRegions.append(TimelineWaveformRegion(start: input.start, duration: input.duration, waveform: input.originalWaveform))
        if originalRegions.count > 32 { originalRegions.removeFirst(originalRegions.count - 32) }
    }
    private func rememberProcessed(_ input: PreparedMediaPreview, rendered: RenderedMediaPreview) {
        processedRegions.removeAll { abs($0.start - input.start) < 0.0001 }
        processedRegions.append(TimelineWaveformRegion(start: input.start, duration: input.duration, waveform: rendered.waveform))
        if processedRegions.count > 32 { processedRegions.removeFirst(processedRegions.count - 32) }
    }

    private func startOverview(info: PreviewMediaInfo, trackID: CMPersistentTrackID) {
        guard overviewSource != info.source || overviewTrack != trackID else { return }
        resetOverview()
        overviewSource = info.source; overviewTrack = trackID
        isOverviewLoading = true
        let generation = overviewGeneration
        overviewTask = Task { [weak self] in
            let worker = Task.detached(priority: .utility) { [weak self] in
                try await MediaPreviewRenderer.overview(info: info, trackID: trackID) { [weak self] value in
                    Task { @MainActor [weak self] in
                        guard let self, self.overviewGeneration == generation else { return }
                        self.overviewProgress = value
                    }
                }
            }
            guard let self else { worker.cancel(); return }
            self.overviewWorker = worker
            do {
                let result = try await worker.value
                guard !Task.isCancelled, self.overviewGeneration == generation else { return }
                self.overview = result; self.overviewProgress = 1
                self.isOverviewLoading = false; self.overviewWorker = nil
            } catch {
                guard !Task.isCancelled, self.overviewGeneration == generation else { return }
                self.isOverviewLoading = false; self.overviewWorker = nil
            }
        }
    }

    private func resetOverview() {
        overviewGeneration += 1
        overviewTask?.cancel(); overviewWorker?.cancel()
        overviewTask = nil; overviewWorker = nil
        overview = nil; overviewSource = nil; overviewTrack = nil
        overviewProgress = 0; isOverviewLoading = false
    }
    private func cancelRender() {
        renderGeneration += 1
        renderWorker?.cancel()
        renderWorker = nil; isRendering = false
    }
    private func removeInput() {
        if let input { try? FileManager.default.removeItem(at: input.directory) }
        input = nil; rendered = nil
    }
}

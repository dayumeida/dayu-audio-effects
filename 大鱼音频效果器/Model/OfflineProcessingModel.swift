import Foundation
import Observation
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

enum OfflineJobState: Sendable { case queued, running, completed, failed, cancelled }

struct OfflineMediaJob: Identifiable, Sendable {
    let id = UUID()
    let source: URL
    var state: OfflineJobState = .queued
    var progress = 0.0
    var message = "待输出"
    var output: URL?
}

@MainActor @Observable
final class OfflineProcessingModel {
    private(set) var jobs: [OfflineMediaJob] = []
    private(set) var isProcessing = false
    private(set) var isCancelling = false
    private(set) var effectTitle = ""
    var error: String?
    private var task: Task<Void, Never>?
    private var worker: Task<URL, Error>?
    private var sourceScopes: [URL: ScopedSourceAccess] = [:]

    var overallProgress: Double {
        guard !jobs.isEmpty else { return 0 }
        return jobs.map { job in
            switch job.state {
            case .completed, .failed, .cancelled: 1.0
            case .running: job.progress
            case .queued: 0.0
            }
        }.reduce(0, +) / Double(jobs.count)
    }
    var summary: String {
        let done = jobs.filter { $0.state == .completed }.count
        let failed = jobs.filter { $0.state == .failed }.count
        let cancelled = jobs.filter { $0.state == .cancelled }.count
        let pending = jobs.filter { $0.state == .queued }.count
        if isCancelling { return "正在取消并清理临时文件…" }
        if isProcessing { return "已完成 \(done)/\(jobs.count) · \(effectTitle)" }
        if pending > 0 { return "待输出 \(pending) 个文件" }
        return "完成 \(done) 个" + (failed > 0 ? " · 失败 \(failed) 个" : "") + (cancelled > 0 ? " · 已取消 \(cancelled) 个" : "")
    }

    /// Import only stages input files. Source-directory access is requested by
    /// begin(settings:) after the user explicitly clicks the export button.
    @discardableResult func stage(_ urls: [URL]) -> URL? {
        guard !isProcessing else { return nil }
        error = nil
        var first: URL?
        for source in urls {
            guard source.isFileURL, let type = UTType(filenameExtension: source.pathExtension),
                  type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .video) else {
                error = "请选择受支持的音频或视频文件。"
                continue
            }
            let key = source.standardizedFileURL
            if sourceScopes[key] == nil { sourceScopes[key] = ScopedSourceAccess(source) }
            if let index = jobs.firstIndex(where: { $0.source.standardizedFileURL == key }) {
                jobs[index].state = .queued
                jobs[index].message = "待输出"
                jobs[index].output = nil
            } else { jobs.append(OfflineMediaJob(source: source)) }
            if first == nil { first = source }
        }
        return first
    }

    func begin(settings: OfflineEffectSettings) {
        begin(urls: jobs.map(\.source), settings: settings)
    }

    func remove(_ id: UUID) {
        guard !isProcessing, let job = jobs.first(where: { $0.id == id }) else { return }
        jobs.removeAll { $0.id == id }
        sourceScopes.removeValue(forKey: job.source.standardizedFileURL)
    }

    private func begin(urls: [URL], settings: OfflineEffectSettings) {
        guard !isProcessing else { return }
        var seen = Set<URL>()
        let sources = urls.filter { seen.insert($0.standardizedFileURL).inserted }
        guard !sources.isEmpty else { return }
        jobs = sources.map { OfflineMediaJob(source: $0) }
        error = nil
        effectTitle = settings.kind.title + (settings.bypass ? "（旁通）" : "")
        isProcessing = true
        isCancelling = false
        task = Task { [weak self] in
            guard let self else { return }
            var grants: [URL] = []
            var authorized = Set<URL>()
            var denied: [URL: String] = [:]
            defer {
                grants.forEach { $0.stopAccessingSecurityScopedResource() }
                for index in self.jobs.indices where self.jobs[index].state == .queued || self.jobs[index].state == .running {
                    self.jobs[index].state = .cancelled
                    self.jobs[index].message = "已取消"
                }
                self.isProcessing = false
                self.isCancelling = false
                self.worker = nil
                self.task = nil
            }
            for index in self.jobs.indices {
                if Task.isCancelled { break }
                let source = self.jobs[index].source
                let parent = source.deletingLastPathComponent().standardizedFileURL
                let id = self.jobs[index].id
                self.jobs[index].state = .running
                self.jobs[index].message = "正在检查原目录写入权限"
                do {
                    guard source.isFileURL, let type = UTType(filenameExtension: source.pathExtension),
                          type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .video) else {
                        throw OfflineMediaError.message("请导入受支持的音频或视频文件。")
                    }
                    if let reason = denied[parent] { throw OfflineMediaError.message(reason) }
                    if !authorized.contains(parent) {
                        do {
                            if let grant = try await self.authorize(directory: parent) { grants.append(grant) }
                            authorized.insert(parent)
                        } catch is CancellationError { throw CancellationError() }
                        catch { denied[parent] = error.localizedDescription; throw error }
                    }
                    try Task.checkCancellation()
                    let worker = Task.detached(priority: .userInitiated) { [weak self] in
                        try await OfflineMediaProcessor.process(source: source, settings: settings) { [weak self] value, message in
                            Task { @MainActor [weak self] in
                                guard let self, let current = self.jobs.firstIndex(where: { $0.id == id }),
                                      self.jobs[current].state == .running else { return }
                                self.jobs[current].progress = value
                                self.jobs[current].message = message
                            }
                        }
                    }
                    self.worker = worker
                    let output = try await worker.value
                    self.jobs[index].output = output
                    self.jobs[index].progress = 1
                    self.jobs[index].state = .completed
                    self.jobs[index].message = "已保存到原文件目录"
                } catch is CancellationError {
                    self.jobs[index].state = .cancelled
                    self.jobs[index].message = "已取消"
                    break
                } catch {
                    self.jobs[index].state = .failed
                    self.jobs[index].message = error.localizedDescription
                }
            }
        }
    }

    func cancel() {
        guard isProcessing else { return }
        isCancelling = true
        worker?.cancel()
        task?.cancel()
    }

    func clear() {
        guard !isProcessing else { return }
        jobs = []
        error = nil
        sourceScopes = [:]
    }

    private func authorize(directory: URL) async throws -> URL? {
        do { try probeWrite(directory); return nil }
        catch {
            guard isPermissionError(error as NSError) else { throw error }
        }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "允许在原目录保存处理副本"
        panel.message = "请选择「\(directory.lastPathComponent)」目录，允许在原文件旁保存处理后的副本。"
        panel.prompt = "授权此目录"
        panel.directoryURL = directory
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        let response: NSApplication.ModalResponse = await withCheckedContinuation { continuation in
            if let window = NSApplication.shared.keyWindow {
                panel.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            } else { panel.begin { continuation.resume(returning: $0) } }
        }
        guard response == .OK, let selected = panel.url else { throw CancellationError() }
        guard selected.resolvingSymlinksInPath().standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else {
            throw OfflineMediaError.message("请选择原文件所在目录「\(directory.lastPathComponent)」，以便将副本保存在原目录。")
        }
        let scoped = selected.startAccessingSecurityScopedResource()
        do { try Task.checkCancellation(); try probeWrite(selected) }
        catch { if scoped { selected.stopAccessingSecurityScopedResource() }; throw error }
        return scoped ? selected : nil
        #else
        throw OfflineMediaError.message("无法写入原目录，请先在“文件”中授权目录访问。")
        #endif
    }

    private func probeWrite(_ directory: URL) throws {
        let probe = directory.appendingPathComponent(".dayu-write-check-\(UUID().uuidString)")
        try Data().write(to: probe, options: .withoutOverwriting)
        try FileManager.default.removeItem(at: probe)
    }

    private func isPermissionError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(error.code) { return true }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }
}

/// Balances a staged file's access even when the observable model is destroyed.
nonisolated private final class ScopedSourceAccess: Sendable {
    private let url: URL
    init?(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        self.url = url
    }
    deinit { url.stopAccessingSecurityScopedResource() }
}

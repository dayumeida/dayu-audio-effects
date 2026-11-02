import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct OfflineProcessingView: View {
    let hostModel: AudioUnitHostModel
    @State private var choosingMedia = false
    @State private var targeted = false
    private var model: OfflineProcessingModel { hostModel.offlineProcessing }
    private var preview: MediaPreviewModel { hostModel.mediaPreview }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("调参预览与输出").font(.title2.bold())
                Text("导入素材 → 调参试听 → 输出副本")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Button { choosingMedia = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "waveform.badge.plus").font(.system(size: 28, weight: .light))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(targeted ? "松开以载入预览" : "拖入音频或视频").font(.headline)
                        Text("点此选择 · 支持多个文件").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity).padding(17)
                .background(targeted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(targeted ? Color.accentColor : Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).disabled(model.isProcessing)
            .dropDestination(for: URL.self) { urls, _ in
                guard !model.isProcessing else { return false }
                hostModel.importMedia(urls)
                return !urls.isEmpty
            } isTargeted: { targeted = $0 && !model.isProcessing }
            .accessibilityLabel("导入音频或视频以调参预览")

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if preview.source != nil { MediaPreviewView(hostModel: hostModel) }
                    else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(hostModel.selectedEffect.title, systemImage: "slider.horizontal.3")
                            Text("导入后调整左侧参数，查看处理前后的波形并试听，再点击下方输出按钮。")
                        }.font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
                    }
                    if let error = model.error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                    if !model.jobs.isEmpty {
                        Divider()
                        HStack {
                            Text("素材（\(model.jobs.count)）").font(.callout.weight(.semibold))
                            Spacer()
                            Button("清空") { hostModel.clearMedia() }.disabled(model.isProcessing)
                        }
                        ForEach(model.jobs) { job in jobRow(job) }
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                if model.isProcessing {
                    HStack {
                        Text(model.summary).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("取消输出") { model.cancel() }.disabled(model.isCancelling)
                    }
                    ProgressView(value: model.overallProgress)
                } else {
                    Text(preview.status).font(.caption).foregroundStyle(.secondary)
                    Button { hostModel.exportMedia() } label: {
                        Label(model.jobs.count > 1 ? "输出全部 \(model.jobs.count) 个副本" : "输出副本", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent).disabled(!hostModel.canExport)
                    .keyboardShortcut("e", modifiers: [.command])
                    Text("确认预览后输出完整文件，副本保存到原目录。")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Text("音频输出 WAV；视频画面原轨复制，音轨沿用原编码及目标码率。有损实际码率可能略有波动。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(20)
        .fileImporter(isPresented: $choosingMedia, allowedContentTypes: [.audio, .movie, .video], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): hostModel.importMedia(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { model.error = error.localizedDescription }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayuProcessMedia)) { _ in
            if !model.isProcessing { choosingMedia = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dayuOpenAudio)) { _ in
            if !model.isProcessing { choosingMedia = true }
        }
    }

    private func jobRow(_ job: OfflineMediaJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Button { hostModel.selectMedia(job.source) } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(job.state))
                            .foregroundStyle(job.state == .failed ? Color.red : (job.state == .completed ? Color.green : Color.secondary))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.source.lastPathComponent).font(.callout.weight(.medium)).lineLimit(2).help(job.source.path)
                            Text(job.message).font(.caption).foregroundStyle(job.state == .failed ? Color.red : Color.secondary)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(model.isProcessing)
                Button { hostModel.removeMedia(job) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                    .disabled(model.isProcessing).help("移除此素材")
            }
            if job.state == .running { ProgressView(value: job.progress) }
            if let output = job.output {
                Label(output.lastPathComponent, systemImage: "arrow.up.doc")
                    .font(.caption).lineLimit(2).foregroundStyle(Color.accentColor)
                    .draggable(output).help("拖到 Finder 或剪辑时间线")
                HStack {
                    Text("可拖入时间线").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    #if os(macOS)
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([output]) }.font(.caption)
                    #else
                    ShareLink(item: output) { Text("分享副本") }.font(.caption)
                    #endif
                }
            }
        }
        .padding(11).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(preview.source == job.source ? Color.accentColor.opacity(0.5) : .clear))
    }

    private func icon(_ state: OfflineJobState) -> String {
        switch state {
        case .queued: "doc"
        case .running: "waveform"
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .cancelled: "minus.circle"
        }
    }
}

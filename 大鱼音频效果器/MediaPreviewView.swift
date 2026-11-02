import SwiftUI

struct MediaPreviewView: View {
    let hostModel: AudioUnitHostModel
    private var preview: MediaPreviewModel { hostModel.mediaPreview }
    private var exporting: Bool { hostModel.offlineProcessing.isProcessing }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("时间线预览").font(.headline)
                Spacer()
                Button("更新效果") { preview.refresh() }
                    .font(.caption).disabled(exporting || preview.isPreparing || hostModel.isLoading)
            }
            Text(preview.source?.lastPathComponent ?? "").font(.callout.weight(.medium))
                .lineLimit(2).textSelection(.enabled)
            if let info = preview.info {
                if info.tracks.count > 1 {
                    Picker("预览音轨", selection: Binding(get: { preview.selectedTrackID ?? info.tracks[0].id }, set: { preview.selectTrack($0) })) {
                        ForEach(info.tracks) { track in Text(track.title).tag(track.id) }
                    }.disabled(exporting || preview.isPreparing)
                    Text("输出时处理全部音轨。").font(.caption2).foregroundStyle(.secondary)
                } else if let track = info.tracks.first {
                    Text(track.title).font(.caption).foregroundStyle(.secondary)
                }
                WaveformTimelineView(preview: preview, disabled: exporting)
                HStack(spacing: 9) {
                    Button { preview.play(.original) } label: {
                        Label(preview.playingVersion == .original || preview.isWaitingToPlay && preview.preferredVersion == .original ? "暂停原音" : "播放原音",
                              systemImage: preview.playingVersion == .original ? "pause.fill" : "play.fill")
                    }.disabled(exporting || preview.input == nil && !preview.isPreparing)
                    Button { preview.play(.processed) } label: {
                        Label(preview.playingVersion == .processed || preview.isWaitingToPlay && preview.preferredVersion == .processed ? "暂停效果" : "播放效果",
                              systemImage: preview.playingVersion == .processed ? "pause.fill" : "play.fill")
                    }.disabled(exporting || hostModel.isLoading)
                    Spacer(minLength: 0)
                    Toggle("跟随", isOn: Binding(get: { preview.followsPlayhead }, set: { preview.followsPlayhead = $0 }))
                        .toggleStyle(.checkbox).font(.caption).help("播放时让时间线跟随播放游标")
                }.buttonStyle(.bordered).controlSize(.small)
                Text("全长 \(TimelineTime.string(info.duration)) · 效果波形随试听位置更新")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { ProgressView().controlSize(.small) }
            if let error = preview.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }
}

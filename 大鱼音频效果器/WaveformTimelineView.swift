import SwiftUI
#if os(macOS)
import AppKit
#endif

struct WaveformTimelineView: View {
    let preview: MediaPreviewModel
    let disabled: Bool
    @State private var timecode = "00:00.000"
    @FocusState private var editingTime: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { preview.zoom(factor: 0.5) } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(!preview.viewport.canZoomOut).help("缩小（波形聚焦时按 −）")
                    .accessibilityLabel("缩小波形")
                Button { preview.zoom(factor: 2) } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(!preview.viewport.canZoomIn).help("放大（波形聚焦时按 +）")
                    .accessibilityLabel("放大波形")
                Button("适配窗口") { preview.fitTimeline() }.help("显示整段音频（波形聚焦时按 F）")
                    .accessibilityLabel("适配整个音频到窗口")
                Spacer(minLength: 0)
                Text(String(format: "%.1f×", preview.viewport.total / preview.viewport.span))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.buttonStyle(.bordered).controlSize(.small)
            ruler
            lane(title: "原始", version: .original, color: .secondary)
            lane(title: "处理后 · 已预览区间", version: .processed, color: .accentColor)
            HStack(spacing: 6) {
                Button { preview.panTimeline(by: -preview.viewport.span / 2) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.plain).disabled(preview.viewport.start <= 0).accessibilityLabel("波形向前滚动")
                if preview.viewport.canZoomOut {
                    Slider(value: Binding(get: { preview.viewport.start }, set: { preview.scrollTimeline(to: $0) }),
                           in: 0 ... max(0.001, preview.viewport.total - preview.viewport.span))
                        .controlSize(.mini).accessibilityLabel("波形横向滚动（秒）")
                } else {
                    Rectangle().fill(.secondary.opacity(0.15)).frame(height: 3)
                }
                Button { preview.panTimeline(by: preview.viewport.span / 2) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.plain).disabled(preview.viewport.end >= preview.viewport.total).accessibilityLabel("波形向后滚动")
            }.foregroundStyle(.secondary)
            overview
            HStack {
                TextField("00:00.000", text: $timecode)
                    .font(.system(.callout, design: .monospaced)).textFieldStyle(.roundedBorder)
                    .frame(width: 108).focused($editingTime).accessibilityLabel("播放位置（分钟:秒.毫秒）")
                    .help("输入时间并回车定位，保持当前播放或暂停状态")
                    .onSubmit {
                        if let seconds = TimelineTime.parse(timecode) {
                            preview.seek(to: seconds, autoplay: preview.isPlaying || preview.isWaitingToPlay)
                        }
                        timecode = TimelineTime.string(preview.playheadTime, precise: true)
                        editingTime = false
                    }
                Spacer()
                Text("显示 \(TimelineTime.string(preview.viewport.start))–\(TimelineTime.string(preview.viewport.end))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if preview.isOverviewLoading {
                HStack(spacing: 7) {
                    ProgressView(value: preview.overviewProgress).frame(maxWidth: 90)
                    Text("整段波形 \(Int(preview.overviewProgress * 100))%").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Text("点击播放 · 拖动游标 · ⌥拖动平移 · ⌘滚轮/双指捏合缩放")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .disabled(disabled)
        .onAppear { timecode = TimelineTime.string(preview.playheadTime, precise: true) }
        .onChange(of: preview.playheadTime) { _, time in
            if !editingTime { timecode = TimelineTime.string(time, precise: true) }
        }
    }

    private var ruler: some View {
        Canvas { context, size in
            let view = preview.viewport
            let interval = view.tickInterval
            let first = ceil(view.start / interval) * interval
            var time = first
            while time <= view.end + 0.00001 {
                let x = view.fraction(at: time) * size.width
                var tick = Path(); tick.move(to: CGPoint(x: x, y: size.height - 5)); tick.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(tick, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                context.draw(Text(TimelineTime.string(time, precise: interval < 1)).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                             at: CGPoint(x: min(size.width - 26, max(26, x)), y: 7))
                time += interval
            }
        }.frame(height: 22).accessibilityLabel("音频时间尺")
    }

    private func lane(title: String, version: PreviewPlaybackVersion, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                let peak = version == .original ? preview.input?.originalWaveform.peakDB : preview.rendered?.waveform.peakDB
                if let peak { Text(String(format: "片段峰值 %.1f dBFS", peak)).font(.caption2).monospacedDigit().foregroundStyle(.secondary) }
            }
            Canvas { context, size in
                let view = preview.viewport
                let regions = version == .original ? preview.originalRegions : preview.processedRegions
                let middle = size.height / 2
                var grid = Path()
                var tick = ceil(view.start / view.tickInterval) * view.tickInterval
                while tick <= view.end {
                    let x = view.fraction(at: tick) * size.width
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                    tick += view.tickInterval
                }
                context.stroke(grid, with: .color(.secondary.opacity(0.1)), lineWidth: 1)
                if version == .processed {
                    for region in regions {
                        let a = max(0, view.fraction(at: region.start)) * size.width
                        let b = min(1, view.fraction(at: region.end)) * size.width
                        if b > a { context.fill(Path(CGRect(x: a, y: 0, width: max(1, b-a), height: size.height)), with: .color(color.opacity(0.07))) }
                    }
                }
                var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: middle)); baseline.addLine(to: CGPoint(x: size.width, y: middle))
                context.stroke(baseline, with: .color(.secondary.opacity(0.2)), lineWidth: 1)
                var bars = Path()
                let columns = max(1, min(2048, Int(ceil(size.width))))
                for column in 0 ..< columns {
                    let a = view.time(at: Double(column) / Double(columns))
                    let b = view.time(at: Double(column + 1) / Double(columns))
                    var peak: Float?
                    for region in regions.reversed() {
                        if let value = region.peak(from: a, to: b) { peak = value; break }
                    }
                    if peak == nil, version == .original { peak = preview.overview?.peak(from: a, to: b) }
                    guard let peak else { continue }
                    let x = (Double(column) + 0.5) / Double(columns) * size.width
                    let height = max(0.4, min(1, Double(peak)) * (middle - 4))
                    bars.move(to: CGPoint(x: x, y: middle - height)); bars.addLine(to: CGPoint(x: x, y: middle + height))
                }
                context.stroke(bars, with: .color(color), lineWidth: max(1, size.width / Double(columns) * 0.8))
                let cursorX = view.fraction(at: preview.playheadTime) * size.width
                if cursorX >= 0 && cursorX <= size.width {
                    var cursor = Path(); cursor.move(to: CGPoint(x: cursorX, y: 0)); cursor.addLine(to: CGPoint(x: cursorX, y: size.height))
                    context.stroke(cursor, with: .color(.orange), lineWidth: 1.5)
                    var head = Path(); head.move(to: CGPoint(x: cursorX - 4, y: 0)); head.addLine(to: CGPoint(x: cursorX + 4, y: 0)); head.addLine(to: CGPoint(x: cursorX, y: 6)); head.closeSubpath()
                    context.fill(head, with: .color(.orange))
                }
            }
            .frame(height: 76)
            .background(.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                #if os(macOS)
                TimelineInteractionSurface(preview: preview, version: version, label: title + "音频时间线", disabled: disabled)
                #else
                GeometryReader { geometry in
                    Color.clear.contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0).onEnded { value in
                        preview.seek(to: preview.viewport.time(at: value.location.x / geometry.size.width), version: version)
                    })
                }
                #endif
            }
            .overlay(alignment: .bottomTrailing) {
                if preview.isWaitingToPlay, preview.preferredVersion == version {
                    Text("正在准备试听…").font(.caption2).padding(5).background(.ultraThinMaterial, in: Capsule()).padding(5).allowsHitTesting(false)
                }
            }
        }
    }

    private var overview: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                if let index = preview.overview {
                    var bars = Path()
                    for column in 0 ..< max(1, Int(size.width)) {
                        let a = Double(column) / size.width * index.duration
                        let b = Double(column + 1) / size.width * index.duration
                        let peak = Double(index.peak(from: a, to: b))
                        let height = max(0.4, min(1, peak) * (size.height / 2 - 2))
                        bars.move(to: CGPoint(x: Double(column), y: size.height / 2 - height))
                        bars.addLine(to: CGPoint(x: Double(column), y: size.height / 2 + height))
                    }
                    context.stroke(bars, with: .color(.secondary.opacity(0.5)), lineWidth: 1)
                }
                let total = max(0.001, preview.viewport.total)
                let rect = CGRect(x: preview.viewport.start / total * size.width, y: 1,
                    width: max(3, preview.viewport.span / total * size.width), height: size.height - 2)
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.12)))
                context.stroke(Path(rect), with: .color(.accentColor), lineWidth: 1)
            }
            .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                preview.scrollTimeline(to: min(1, max(0, value.location.x / geometry.size.width)) * preview.viewport.total - preview.viewport.span / 2)
            })
        }.frame(height: 27).accessibilityLabel("整段波形导航，拖动选择显示范围")
    }
}

#if os(macOS)
private struct TimelineInteractionSurface: NSViewRepresentable {
    let preview: MediaPreviewModel
    let version: PreviewPlaybackVersion
    let label: String
    let disabled: Bool
    func makeNSView(context: Context) -> TimelineEventView { TimelineEventView() }
    func updateNSView(_ view: TimelineEventView, context: Context) {
        view.timelineLabel = label
        view.total = preview.info?.duration ?? 0
        view.cursor = preview.playheadTime
        view.disabled = disabled
        view.onSeek = { preview.seek(to: $0, version: version) }
        view.onScrub = { preview.scrub(to: $0) }
        view.visibleStart = preview.viewport.start
        view.visibleSpan = preview.viewport.span
        view.onPan = { preview.panTimeline(by: $0) }
        view.onZoom = { factor, fraction in preview.zoom(factor: factor, anchor: preview.viewport.time(at: fraction)) }
        view.onFit = { preview.fitTimeline() }
        view.onPlay = { preview.play(version) }
    }
}

private final class TimelineEventView: NSView {
    var timelineLabel = "音频时间线"
    var total = 0.0
    var cursor = 0.0
    var visibleStart = 0.0
    var visibleSpan = 1.0
    var disabled = false
    var onSeek: ((Double) -> Void)?
    var onScrub: ((Double) -> Void)?
    var onPan: ((Double) -> Void)?
    var onZoom: ((Double, Double) -> Void)?
    var onFit: (() -> Void)?
    var onPlay: (() -> Void)?
    private var lastX = 0.0
    private var isPanning = false
    private var downStart = 0.0
    private var downSpan = 1.0
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    private func fraction(_ event: NSEvent) -> Double {
        min(1, max(0, convert(event.locationInWindow, from: nil).x / max(1, bounds.width)))
    }
    override func mouseDown(with event: NSEvent) {
        guard !disabled else { return }
        window?.makeFirstResponder(self)
        isPanning = event.modifierFlags.contains(.option)
        lastX = convert(event.locationInWindow, from: nil).x
        downStart = visibleStart; downSpan = visibleSpan
    }
    override func mouseDragged(with event: NSEvent) {
        guard !disabled else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if isPanning { onPan?(-(x - lastX) / max(1, bounds.width) * visibleSpan) }
        else { onScrub?(min(total, max(0, downStart + fraction(event) * downSpan))) }
        lastX = x
    }
    override func mouseUp(with event: NSEvent) {
        guard !disabled, !isPanning else { return }
        onSeek?(min(total, max(0, downStart + fraction(event) * downSpan)))
    }
    override func scrollWheel(with event: NSEvent) {
        guard !disabled else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            onZoom?(min(2, max(0.5, exp(Double(event.scrollingDeltaY) * 0.025))), fraction(event))
        } else if abs(event.scrollingDeltaX) > 0.1 || event.modifierFlags.contains(.shift) {
            let delta = abs(event.scrollingDeltaX) > 0.1 ? event.scrollingDeltaX : event.scrollingDeltaY
            onPan?(Double(delta) / max(1, bounds.width) * visibleSpan)
        } else { super.scrollWheel(with: event) }
    }
    override func magnify(with event: NSEvent) {
        guard !disabled else { return }
        onZoom?(exp(Double(event.magnification)), fraction(event))
    }
    override func keyDown(with event: NSEvent) {
        guard !disabled else { return }
        switch event.charactersIgnoringModifiers {
        case "+", "=": onZoom?(2, min(1, max(0, (cursor - visibleStart) / visibleSpan)))
        case "-": onZoom?(0.5, min(1, max(0, (cursor - visibleStart) / visibleSpan)))
        case "f", "F": onFit?()
        case " ": onPlay?()
        default: super.keyDown(with: event)
        }
    }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .slider }
    override func accessibilityLabel() -> String? { timelineLabel }
    override func accessibilityValue() -> Any? { NSNumber(value: cursor) }
    override func accessibilityMinValue() -> Any? { NSNumber(value: 0) }
    override func accessibilityMaxValue() -> Any? { NSNumber(value: total) }
    override func setAccessibilityValue(_ value: Any?) {
        guard !disabled, let value = value as? NSNumber else { return }
        onSeek?(min(total, max(0, value.doubleValue)))
    }
    override func accessibilityPerformIncrement() -> Bool { guard !disabled else { return false }; onSeek?(min(total, cursor + 1)); return true }
    override func accessibilityPerformDecrement() -> Bool { guard !disabled else { return false }; onSeek?(max(0, cursor - 1)); return true }
}
#endif

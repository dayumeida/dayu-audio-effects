import SwiftUI
import UniformTypeIdentifiers

private let panelTint = Color(red: 0.78, green: 0.88, blue: 0.87)
private let panelBundle = Bundle(for: _______ExtensionAudioUnit.self)
#if os(macOS)
private typealias PanelNativeImage = NSImage
#else
private typealias PanelNativeImage = UIImage
#endif
private enum PanelAssets {
    static let images: [String: PanelNativeImage] = {
        var result: [String: PanelNativeImage] = [:]
        for name in ["background", "largeknob", "slider-button-on", "slider-empty", "slider-filled", "display", "levelbar_on", "levelbar_off"] {
            if let url = panelBundle.url(forResource: "Leveler-" + name, withExtension: "tiff") {
                #if os(macOS)
                result["Leveler-" + name] = NSImage(contentsOf: url)
                #else
                result["Leveler-" + name] = UIImage(contentsOfFile: url.path)
                #endif
            }
        }
        return result
    }()
}
private func panelImage(_ name: String) -> Image {
    #if os(macOS)
    return Image(nsImage: PanelAssets.images[name] ?? NSImage())
    #else
    return Image(uiImage: PanelAssets.images[name] ?? UIImage())
    #endif
}

struct _______ExtensionMainView: View {
    var parameterTree: ObservableAUParameterGroup
    var audioUnit: _______ExtensionAudioUnit
    @State private var bypass = false
    @State private var output: Float = -120
    @State private var receivedAudio = false
    @State private var warmupRemaining = 0.0
    @State private var before = [Float](repeating: 0, count: 256)
    @State private var after = [Float](repeating: 0, count: 256)
    @State private var advanced = false
    @State private var showInfo = false
    @State private var loading = false
    @State private var saving = false
    @State private var status = ""
    @State private var presetDocument = LevelerPresetDocument()

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    panel.scaleEffect(geometry.size.width / 400, anchor: .topLeading)
                }
                .aspectRatio(400.0 / 405.0, contentMode: .fit)
                Text(audioUnit.isLowLatencyMode ? "低延迟剪辑 · \(audioUnit.latency * 1000, specifier: "%.2f") ms" : "原版参考 · \(audioUnit.latency, specifier: "%.3f") 秒预读")
                    .font(.caption).foregroundStyle(panelTint.opacity(0.8)).padding(.top, 8)
                if !receivedAudio {
                    Text("等待宿主音频；播放后显示实时波形").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                } else if warmupRemaining > 0.02 {
                    Text("输入已到达 · 预读剩余 \(warmupRemaining, specifier: "%.1f") 秒音频")
                        .font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
                DisclosureGroup("高级设置", isExpanded: $advanced) {
                    VStack(spacing: 4) {
                        ParameterSlider(param: parameterTree.global.maxBoost)
                        ParameterSlider(param: parameterTree.global.response)
                        ParameterSlider(param: parameterTree.global.noiseFloor)
                        ParameterSlider(param: parameterTree.global.outputGain)
                        ParameterSlider(param: parameterTree.global.ceiling)
                        Text(audioUnit.isLowLatencyMode ? "目标为 RMS 电平；低延迟模式使用因果检测，不等待未来语句。" : "目标采用参考插件的电平标尺。当前宿主补偿延迟：\(audioUnit.latency, specifier: "%.3f") 秒。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.top, 10)
                }
                .padding(.horizontal, 22).padding(.vertical, 12)
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(panelTint).padding(.horizontal, 22).padding(.bottom, 12)
                }
            }
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
        }
        .frame(minWidth: 400, minHeight: 450)
        .background(Color(red: 0.14, green: 0.15, blue: 0.18))
        .foregroundStyle(panelTint)
        .tint(panelTint)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $loading, allowedContentTypes: [.json]) { result in loadPreset(result) }
        .fileExporter(isPresented: $saving, document: presetDocument, contentType: .json, defaultFilename: "大鱼自动电平预设") { result in
            switch result {
            case .success: status = "预设已保存"
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { status = "保存失败：\(error.localizedDescription)" }
            }
        }
        .task {
            while !Task.isCancelled {
                output = audioUnit.meter(1)
                receivedAudio = audioUnit.hasReceivedAudio
                warmupRemaining = audioUnit.warmupRemainingSeconds
                before = (0 ..< 256).map { audioUnit.waveformPoint(0, UInt32($0)) }
                after = (0 ..< 256).map { audioUnit.waveformPoint(1, UInt32($0)) }
                bypass = audioUnit.shouldBypassEffect
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var targetTicks: [Int] { audioUnit.isLowLatencyMode ? [-3, -9, -18, -24, -30] : [0, -6, -12, -18, -24] }
    private func targetTickY(_ value: Int) -> CGFloat {
        let param: ObservableAUParameter = parameterTree.global.targetLevel
        return 139 + CGFloat((param.max - Float(value)) / (param.max - param.min)) * 216
    }

    private var panel: some View {
        ZStack(alignment: .topLeading) {
            panelImage("Leveler-background").resizable().frame(width: 400, height: 405)
            Text("大鱼").font(.system(size: 16, weight: .bold)).position(x: 55, y: 28)
            Text("自动电平").font(.system(size: 19, weight: .regular)).position(x: 200, y: 30)
            Button {
                bypass.toggle(); audioUnit.shouldBypassEffect = bypass
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(bypass ? Color.gray : panelTint).frame(width: 8, height: 8)
                    Text(bypass ? "旁通" : "开启").font(.system(size: 11, weight: .semibold))
                }
                .frame(width: 66, height: 24)
                .background(.black.opacity(0.3), in: Capsule())
                .overlay(Capsule().stroke(.white.opacity(0.16)))
            }
            .buttonStyle(.plain).help("切换处理前后的声音；宿主补偿延迟保持一致")
            .position(x: 345, y: 29)

            Text(audioUnit.isLowLatencyMode ? "目标 RMS" : "目标电平").font(.system(size: 12)).position(x: 55, y: 76)
            ParameterReadout(param: parameterTree.global.targetLevel, suffix: "").position(x: 55, y: 107)
            VerticalParameterSlider(param: parameterTree.global.targetLevel)
                .frame(width: 25, height: 260).position(x: 79, y: 251)
            ForEach(targetTicks, id: \.self) { value in
                Text("\(value)").font(.system(size: 10, design: .monospaced))
                    .position(x: 32, y: targetTickY(value))
            }

            StrengthKnob(param: parameterTree.global.amount).frame(width: 128, height: 168).position(x: 200, y: 134)
            Text("调整强度").font(.system(size: 13)).position(x: 200, y: 230)
            ParameterReadout(param: parameterTree.global.amount, suffix: "%").position(x: 200, y: 264)

            Text("输出").font(.system(size: 12)).position(x: 345, y: 76)
            Text(output < -99 ? "−∞" : String(format: "%.1f", output))
                .font(.system(size: 14, design: .monospaced)).frame(width: 56, height: 28)
                .background(panelImage("Leveler-display").resizable()).position(x: 345, y: 107)
            outputMeter.frame(width: 10, height: 208).position(x: 322, y: 245)
            ForEach([0, -6, -12, -18, -24, -30], id: \.self) { value in
                Text("\(value)").font(.system(size: 10, design: .monospaced))
                    .position(x: 367, y: 143 + CGFloat(-value) / 30 * 204)
            }
            Text(output < -99 ? "−∞" : String(format: "%.1f", output))
                .font(.system(size: 10, design: .monospaced)).position(x: 343, y: 367)

            WaveformOverlay(before: before, after: after)
                .frame(width: 182, height: 76).position(x: 200, y: 329)
                .accessibilityLabel("实时波形：蓝灰为输入，白色为处理后")
            panelButton("保存", symbol: "square.and.arrow.down", x: 131) { savePreset() }
            panelButton("载入", symbol: "folder", x: 177) { loading = true }
            panelButton("重置", symbol: "arrow.counterclockwise", x: 223) { resetParameters() }
            panelButton("帮助", symbol: "info.circle", x: 269) { showInfo.toggle() }
                .popover(isPresented: $showInfo) { helpContent }
        }
        .frame(width: 400, height: 405)
    }

    private var outputMeter: some View {
        GeometryReader { geometry in
            let fraction = CGFloat(min(1, max(0, (output + 30) / 30)))
            ZStack(alignment: .bottom) {
                panelImage("Leveler-levelbar_off").resizable()
                panelImage("Leveler-levelbar_on").resizable()
                    .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * fraction) }
            }
        }
    }
    private func panelButton(_ title: String, symbol: String, x: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 8))
            }.frame(width: 40, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(title).position(x: x, y: 390)
    }
    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("自动电平使用说明").font(.headline)
            Text("先设置左侧目标电平，再调整中央强度。强度越高，音量越接近目标；强度越低，保留的动态越多。")
            Text("波形中，蓝灰为原始声音，白色为处理后声音。右侧数字与电平条显示输出电平；输出增益可在高级设置中调整。")
            Text("保存和载入使用 JSON 预设文件。重置恢复所有参数。高级设置可以调整提升上限、最短分段、活动门槛和附加峰值保护。")
            Text(audioUnit.isLowLatencyMode ? "峰值上限控制采样峰值保护；默认 −1 dBFS。" : "峰值上限为 0 dB 时使用参考限幅器；设置负值才会开启新增采样峰值保护。")
            Text(audioUnit.isLowLatencyMode ? "低延迟剪辑版：300 ms 滚动检测、快降慢升、约 5 ms 峰值保护。适合 FCP 拖动和剪切；声音不承诺与原版长窗口逐样本一致。" : "原版参考版：保留长窗口与约 7.5 秒前瞻。FCP 重新计算整段时间线波形时仍需处理素材；它适合声音对照，剪辑建议换用“低延迟”效果。")
        }.font(.callout).padding(22).frame(width: 350)
    }
    private func savePreset() {
        var values: [String: Float] = [:]
        for parameter in audioUnit.parameterTree?.allParameters ?? [] { values[parameter.identifier] = parameter.value }
        presetDocument = LevelerPresetDocument(parameters: values, mode: audioUnit.effectKind.rawValue)
        saving = true
    }
    private func loadPreset(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let preset = try JSONDecoder().decode(LevelerPreset.self, from: Data(contentsOf: url))
            guard preset.format == "dayu-leveler", preset.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
            let mode = audioUnit.effectKind.rawValue
            guard (preset.mode ?? "reference") == mode else {
                throw NSError(domain: "DayuPreset", code: 1, userInfo: [NSLocalizedDescriptionKey: "预设模式不同，请在对应的低延迟或参考版效果中载入。"])
            }
            for parameter in audioUnit.parameterTree?.allParameters ?? [] {
                if let value = preset.parameters[parameter.identifier], value.isFinite {
                    parameter.value = min(parameter.maxValue, max(parameter.minValue, value))
                }
            }
            status = "已载入：\(url.lastPathComponent)"
        } catch { status = "载入失败：\(error.localizedDescription)" }
    }
    private func resetParameters() {
        let defaults = audioUnit.defaultParameterValues
        for parameter in audioUnit.parameterTree?.allParameters ?? [] {
            if Int(parameter.address) < defaults.count { parameter.value = defaults[Int(parameter.address)] }
        }
        status = "已恢复默认参数"
    }
}

private struct ParameterReadout: View {
    @State var param: ObservableAUParameter
    var suffix: String
    var body: some View {
        HStack(spacing: 1) {
            TextField("", value: $param.value, format: .number.precision(.fractionLength(param.unit == .percent ? 0 : 1)))
                .textFieldStyle(.plain).multilineTextAlignment(.center)
                .onSubmit { param.value = min(param.max, max(param.min, param.value)) }
            if !suffix.isEmpty { Text(suffix).font(.system(size: 10)) }
        }
        .font(.system(size: 14, design: .monospaced)).foregroundStyle(panelTint)
        .frame(width: 50, height: 24)
        .background(panelImage("Leveler-display").resizable().frame(width: 56, height: 28))
        .accessibilityLabel(param.displayName)
    }
}

private struct VerticalParameterSlider: View {
    @State var param: ObservableAUParameter
    @State private var dragging = false
    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat((param.value - param.min) / (param.max - param.min))
            ZStack(alignment: .bottom) {
                panelImage("Leveler-slider-empty").resizable().frame(width: 10)
                panelImage("Leveler-slider-filled").resizable().frame(width: 10)
                    .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * fraction) }
                panelImage("Leveler-slider-button-on").resizable()
                    .frame(width: 26, height: 44).position(x: geometry.size.width / 2, y: (1 - fraction) * (geometry.size.height - 30) + 15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                if !dragging { dragging = true; param.onEditingChanged(true) }
                let value = 1 - min(1, max(0, (gesture.location.y - 15) / (geometry.size.height - 30)))
                param.value = param.min + Float(value) * (param.max - param.min)
            }.onEnded { _ in dragging = false; param.onEditingChanged(false) })
            .accessibilityLabel(param.displayName)
            .accessibilityValue(String(format: "%.1f dB", param.value))
            .accessibilityAdjustableAction { direction in
                param.value = min(param.max, max(param.min, param.value + (direction == .increment ? 1 : -1)))
            }
        }
    }
}

private struct StrengthKnob: View {
    @State var param: ObservableAUParameter
    @State private var start: Float?
    var body: some View {
        ZStack {
            panelImage("Leveler-largeknob").resizable()
            ForEach(0 ..< 29, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.6)
                    .fill(Float(index) / 28 <= param.value / 100 ? Color(red: 0.76, green: 0.31, blue: 0.27) : Color.white.opacity(0.10))
                    .frame(width: 4.8, height: 3.8)
                    .offset(y: -61).rotationEffect(.degrees(-140 + Double(index) * 10))
                    .position(x: 64, y: 84)
            }
            RoundedRectangle(cornerRadius: 1)
                .fill(panelTint).frame(width: 2.5, height: 13)
                .offset(y: -43).rotationEffect(.degrees(-140 + Double(param.value) * 2.8))
                .position(x: 64, y: 84)
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
            if start == nil { start = param.value; param.onEditingChanged(true) }
            param.value = min(param.max, max(param.min, (start ?? param.value) - Float(gesture.translation.height) * 0.6))
        }.onEnded { _ in start = nil; param.onEditingChanged(false) })
        .accessibilityLabel(param.displayName)
        .accessibilityValue(String(format: "%.0f %%", param.value))
        .accessibilityAdjustableAction { direction in
            param.value = min(param.max, max(param.min, param.value + (direction == .increment ? 1 : -1)))
        }
    }
}

private struct WaveformOverlay: View {
    let before: [Float]
    let after: [Float]
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black.opacity(0.10)))
            let center = size.height / 2
            for (values, color) in [(before, Color(red: 0.43, green: 0.60, blue: 0.62)), (after, Color.white.opacity(0.86))] {
                var path = Path()
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) / CGFloat(max(1, values.count - 1)) * size.width
                    let amplitude = CGFloat(min(1, max(0, value))) * (center - 3)
                    path.move(to: CGPoint(x: x, y: center - amplitude))
                    path.addLine(to: CGPoint(x: x, y: center + amplitude))
                }
                context.stroke(path, with: .color(color), lineWidth: 0.8)
            }
            var baseline = Path(); baseline.move(to: CGPoint(x: 0, y: center)); baseline.addLine(to: CGPoint(x: size.width, y: center))
            context.stroke(baseline, with: .color(panelTint.opacity(0.4)), style: StrokeStyle(lineWidth: 1, dash: [1, 3]))
        }
    }
}

private struct LevelerPreset: Codable {
    var format = "dayu-leveler"
    var version = 1
    var parameters: [String: Float]
    var mode: String? = nil
}
private struct LevelerPresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var preset: LevelerPreset
    init(parameters: [String: Float] = [:], mode: String? = nil) { preset = LevelerPreset(parameters: parameters, mode: mode) }
    init(configuration: ReadConfiguration) throws {
        preset = try JSONDecoder().decode(LevelerPreset.self, from: configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(preset))
    }
}

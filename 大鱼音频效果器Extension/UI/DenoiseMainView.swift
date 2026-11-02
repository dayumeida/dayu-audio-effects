import SwiftUI
import UniformTypeIdentifiers

struct DenoiseMainView: View {
    let parameterTree: ObservableAUParameterGroup
    let audioUnit: _______ExtensionAudioUnit
    @State private var output: Float = -120
    @State private var before = [Float](repeating: 0, count: 256)
    @State private var after = [Float](repeating: 0, count: 256)
    @State private var bypass = false
    @State private var loading = false
    @State private var saving = false
    @State private var showHelp = false
    @State private var received = false
    @State private var warmup = 0.0
    @State private var status = ""
    @State private var preset = EffectPresetDocument()

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                GeometryReader { geometry in panel.scaleEffect(geometry.size.width / 400, anchor: .topLeading) }
                    .aspectRatio(400.0 / 536, contentMode: .fit)
                Text("宿主补偿延迟：\(audioUnit.latency * 1000, specifier: "%.1f") ms").font(.caption)
                if !received { Text("等待宿主音频").font(.caption).foregroundStyle(.secondary) }
                else if warmup > 0 { Text("分析中 · 剩余 \(warmup, specifier: "%.2f") 秒音频").font(.caption).foregroundStyle(.secondary) }
                if !status.isEmpty { Text(status).font(.caption).padding(.horizontal) }
            }.frame(maxWidth: 400).frame(maxWidth: .infinity)
                .padding(.top, 32).padding(.bottom, 32)
        }
        .frame(minWidth: 400, minHeight: 560)
        .background(Color(red: 0.14, green: 0.15, blue: 0.18)).foregroundStyle(effectPanelTint).tint(effectPanelTint)
        .environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $loading, allowedContentTypes: [.json]) { status = loadEffectPreset($0, into: audioUnit) }
        .fileExporter(isPresented: $saving, document: preset, contentType: .json, defaultFilename: "大鱼智能降噪预设") { result in
            switch result {
            case .success: status = "预设已保存"
            case .failure(let error): status = "保存失败：\(error.localizedDescription)"
            }
        }
        .task {
            while !Task.isCancelled {
                output = audioUnit.meter(1)
                received = audioUnit.hasReceivedAudio
                warmup = audioUnit.warmupRemainingSeconds
                bypass = audioUnit.shouldBypassEffect || (audioUnit.parameterTree?.parameter(withAddress: 1)?.value ?? 1) < 0.5
                before = (0 ..< 256).map { audioUnit.waveformPoint(0, UInt32($0)) }
                after = (0 ..< 256).map { audioUnit.waveformPoint(1, UInt32($0)) }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var panel: some View {
        ZStack(alignment: .topLeading) {
            EffectPanelAssets.image("background").resizable().frame(width: 400, height: 536)
            Text("大鱼").font(.system(size: 16, weight: .bold)).position(x: 55, y: 30)
            Text("智能降噪").font(.system(size: 19, weight: .medium)).position(x: 200, y: 30)
            Button {
                let active: ObservableAUParameter = parameterTree.global.active
                active.value = bypass ? 1 : 0
                audioUnit.shouldBypassEffect = false
                bypass.toggle()
            } label: {
                HStack(spacing: 5) {
                    Circle().fill(bypass ? .gray : effectPanelTint).frame(width: 8, height: 8)
                    Text(bypass ? "旁通" : "开启").font(.system(size: 11, weight: .semibold))
                }.frame(width: 66, height: 24).background(.black.opacity(0.3), in: Capsule())
            }.buttonStyle(.plain).position(x: 345, y: 29)
                .help("切换处理前后的声音；延迟保持一致")

            Text("输出增益").font(.system(size: 12)).position(x: 55, y: 76)
            EffectParameterReadout(parameter: parameterTree.global.outputGain).position(x: 55, y: 107)
            EffectVerticalSlider(parameter: parameterTree.global.outputGain)
                .frame(width: 25, height: 260).position(x: 79, y: 251)
            ForEach([24, 12, 0, -12, -24], id: \.self) { value in
                Text("\(value)").font(.system(size: 11, design: .monospaced))
                    .position(x: 32, y: 138 + CGFloat(24 - value) * 4.5)
            }
            Text("dB").font(.system(size: 10)).position(x: 32, y: 370)

            EffectParameterKnob(parameter: parameterTree.global.strength).position(x: 200, y: 134)
            Text("降噪强度").font(.system(size: 13)).position(x: 200, y: 207)
            EffectParameterReadout(parameter: parameterTree.global.strength).position(x: 200, y: 238)
            EffectWaveform(before: before, after: after).frame(width: 182, height: 76).position(x: 200, y: 329)

            Text("输出电平").font(.system(size: 12)).position(x: 345, y: 76)
            Text(output < -99 ? "−∞" : String(format: "%.1f", output))
                .font(.system(size: 13, design: .monospaced)).frame(width: 56, height: 28)
                .background(EffectPanelAssets.image("display").resizable()).position(x: 345, y: 107)
            GeometryReader { geometry in
                ZStack(alignment: .bottom) {
                    EffectPanelAssets.image("levelbar_off").resizable()
                    EffectPanelAssets.image("levelbar_on").resizable()
                        .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * CGFloat(min(1, max(0, (output + 60) / 60)))) }
                }
            }.frame(width: 10, height: 206).position(x: 322, y: 246)
            ForEach([0, -9, -21, -33, -45, -57], id: \.self) { value in
                Text("\(value)").font(.system(size: 10, design: .monospaced))
                    .position(x: 367, y: 141 + CGFloat(-value) / 60 * 216)
            }
            Text("dB").font(.system(size: 10)).position(x: 367, y: 364)
            panelButton("保存", symbol: "square.and.arrow.down", x: 132) {
                preset = EffectPresetDocument(effect: audioUnit.effectKind.rawValue, parameters: effectParameterSnapshot(audioUnit)); saving = true
            }
            panelButton("载入", symbol: "folder", x: 177) { loading = true }
            panelButton("重置", symbol: "arrow.counterclockwise", x: 223) { resetEffectParameters(audioUnit); status = "已恢复默认参数" }
            panelButton("帮助", symbol: "info.circle", x: 269) { showHelp.toggle() }
                .popover(isPresented: $showHelp) { helpContent }

            band("低频", parameter: parameterTree.global.low, x: 77)
            band("中频", parameter: parameterTree.global.mid, x: 200)
            band("高频", parameter: parameterTree.global.high, x: 323)
        }.frame(width: 400, height: 536)
    }
    private func band(_ title: String, parameter: ObservableAUParameter, x: CGFloat) -> some View {
        ZStack {
            Text(title).font(.system(size: 12)).position(x: x, y: 417)
            EffectParameterKnob(parameter: parameter, small: true).position(x: x, y: 467)
            EffectParameterReadout(parameter: parameter, small: true).position(x: x, y: 505)
        }
    }
    private func panelButton(_ title: String, symbol: String, x: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) { Image(systemName: symbol).font(.system(size: 10)); Text(title).font(.system(size: 8)) }
                .frame(width: 43, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).position(x: x, y: 379).help(title)
    }
    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("智能降噪使用说明").font(.headline)
            Text("中央旋钮调整整体降噪强度。底部三个旋钮控制低、中、高频的处理量；降低某一频段的数值可以保留该频段更多原声。")
            Text("左侧调整输出增益，右侧显示输出电平。旁通保留同样的宿主补偿延迟，便于听音对照。")
            Text("模型使用约半秒音频上下文。跳转后需要重新积累音频；时间线波形的总重建时间由素材长度与宿主调度共同决定。")
            Text("保存和载入使用此效果专用的 JSON 预设。")
        }.font(.callout).padding(22).frame(width: 330)
    }
}

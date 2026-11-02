import SwiftUI
import UniformTypeIdentifiers

private let repairTint = Color(red: 0.08, green: 0.77, blue: 0.80)

struct DeclipMainView: View {
    let parameterTree: ObservableAUParameterGroup
    let audioUnit: _______ExtensionAudioUnit
    var onResize: ((CGSize) -> Void)? = nil
    @State private var expanded = false
    @State private var level: Float = -120
    @State private var activity: Float = 0
    @State private var bypass = false
    @State private var showHelp = false
    @State private var slotA = true
    @State private var a: [String: Float] = [:]
    @State private var b: [String: Float] = [:]
    @State private var loading = false
    @State private var saving = false
    @State private var status = ""
    @State private var preset = EffectPresetDocument()

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                GeometryReader { geometry in panel.scaleEffect(geometry.size.width / 300, anchor: .topLeading) }
                    .aspectRatio(300.0 / 420, contentMode: .fit)
                HStack {
                    Button("保存预设") { preset = EffectPresetDocument(effect: audioUnit.effectKind.rawValue, parameters: effectParameterSnapshot(audioUnit)); saving = true }
                    Button("载入预设") { loading = true }
                    Button("恢复默认") { resetEffectParameters(audioUnit) }
                }.font(.caption)
                Text("宿主补偿延迟：\(audioUnit.latency * 1000, specifier: "%.2f") ms").font(.caption).foregroundStyle(.secondary)
                if !status.isEmpty { Text(status).font(.caption).padding(.horizontal) }
            }.frame(maxWidth: expanded ? 450 : 340).frame(maxWidth: .infinity)
                .padding(.top, 32).padding(.bottom, 32)
        }
        .frame(minWidth: 300, minHeight: 460).background(Color(white: 0.13))
        .foregroundStyle(.white).tint(repairTint).environment(\.colorScheme, .dark)
        .fileImporter(isPresented: $loading, allowedContentTypes: [.json]) { status = loadEffectPreset($0, into: audioUnit) }
        .fileExporter(isPresented: $saving, document: preset, contentType: .json, defaultFilename: "大鱼破音修复预设") { result in
            switch result {
            case .success: status = "预设已保存"
            case .failure(let error): status = "保存失败：\(error.localizedDescription)"
            }
        }
        .task {
            a = effectParameterSnapshot(audioUnit); b = a
            while !Task.isCancelled {
                level = audioUnit.meter(1); activity = audioUnit.meter(3); bypass = audioUnit.shouldBypassEffect || (audioUnit.parameterTree?.parameter(withAddress: 1)?.value ?? 1) < 0.5
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private var panel: some View {
        ZStack(alignment: .topLeading) {
            Color(white: 0.13)
            RepairFooter().fill(Color(white: 0.94)).frame(width: 300, height: 128).offset(y: 272)
            Rectangle().fill(.black).frame(width: 300, height: 20).offset(y: 400)
            Text("大 鱼").font(.system(size: 12, weight: .medium)).position(x: 33, y: 15)
            Text("破音修复").font(.system(size: 14, weight: .semibold)).position(x: 150, y: 16)
            Text("音频修复").font(.system(size: 9)).foregroundStyle(.gray).position(x: 266, y: 16)
            Button {
                let active: ObservableAUParameter = parameterTree.global.active
                active.value = bypass ? 1 : 0
                audioUnit.shouldBypassEffect = false
                bypass.toggle()
            } label: {
                HStack(spacing: 4) {
                    Capsule().fill(bypass ? .gray : repairTint).frame(width: 24, height: 10)
                        .overlay(alignment: bypass ? .leading : .trailing) { Circle().fill(.white).frame(width: 8, height: 8).padding(1) }
                    Text(bypass ? "旁通" : "启用").font(.system(size: 10))
                }.frame(width: 65, height: 22)
            }.buttonStyle(.plain).position(x: 43, y: 41)
            Button { showHelp.toggle() } label: { Image(systemName: "info.circle").font(.system(size: 12)) }
                .buttonStyle(.plain).foregroundStyle(.gray).position(x: 150, y: 40)
                .popover(isPresented: $showHelp) { helpContent }
            HStack(spacing: 5) {
                Button("A") { selectSlot(true) }.foregroundStyle(slotA ? repairTint : .gray)
                Text("/").foregroundStyle(.gray)
                Button("B") { selectSlot(false) }.foregroundStyle(slotA ? .gray : repairTint)
            }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).position(x: 240, y: 40)
                .help("A/B 参数对照")
            Button {
                expanded.toggle()
                onResize?(CGSize(width: expanded ? 650 : 450, height: expanded ? 950 : 700))
            } label: { Image(systemName: expanded ? "minus.magnifyingglass" : "plus.magnifyingglass").font(.system(size: 11)) }
                .buttonStyle(.plain).foregroundStyle(.gray).position(x: 278, y: 40).help(expanded ? "缩小界面" : "放大界面")

            Circle().fill(.black).frame(width: 168, height: 168).position(x: 150, y: 144)
            declipButton.position(x: 150, y: 94)
            Rectangle().fill(.gray.opacity(0.7)).frame(width: 42, height: 0.5).position(x: 150, y: 143)
            Text("处理类型").font(.system(size: 11, weight: .medium)).foregroundStyle(.gray).position(x: 150, y: 155)
            typeButton(0, label: "一").frame(width: 66, height: 50).position(x: 113, y: 192)
            typeButton(1, label: "二").frame(width: 66, height: 50).position(x: 185, y: 192)

            EffectVerticalSlider(parameter: parameterTree.global.outputGain, tint: repairTint, textured: false)
                .frame(width: 20, height: 134).position(x: 51, y: 136)
            ForEach([5, 0, -5, -10, -15, -20, -25, -30], id: \.self) { db in
                Text("\(db)").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.gray)
                    .position(x: 25, y: 69 + CGFloat(5 - db) / 35 * 134)
            }
            Text("输出增益").font(.system(size: 10)).foregroundStyle(.gray).position(x: 40, y: 231)
            gainReadout.position(x: 42, y: 244)
            ZStack(alignment: .bottom) {
                Rectangle().fill(.gray.opacity(0.3))
                Rectangle().fill(repairTint).frame(height: 134 * CGFloat(min(1, max(0, (level + 60) / 60))))
            }.frame(width: 3, height: 134).position(x: 252, y: 136)
            ForEach([0, -10, -20, -30, -40, -50, -60], id: \.self) { db in
                Text("\(db)").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.gray)
                    .position(x: 278, y: 69 + CGFloat(-db) / 60 * 134)
            }
            Text("输出电平").font(.system(size: 10)).foregroundStyle(.gray).position(x: 265, y: 231)
            Text("处理指示").font(.system(size: 12, weight: .medium)).foregroundStyle(.gray).position(x: 150, y: 246)
            HStack(spacing: 3) {
                ForEach(0 ..< 5, id: \.self) { index in
                    Circle().fill(activity > Float(index) / 5 ? repairTint : .black).frame(width: 6, height: 6)
                }
            }.position(x: 150, y: 264)
            Text("处理质量").font(.system(size: 13, weight: .medium)).foregroundStyle(Color(white: 0.13)).position(x: 150, y: 329)
            HStack(spacing: 0) { qualityButton(0, label: "标准"); qualityButton(1, label: "高质量") }
                .frame(width: 260, height: 23).clipShape(Capsule())
                .overlay(Capsule().stroke(Color(white: 0.13), lineWidth: 1))
                .position(x: 150, y: 359)
        }.frame(width: 300, height: 420)
    }
    private var gainReadout: some View {
        let parameter: ObservableAUParameter = parameterTree.global.outputGain
        return Text(String(format: "%.1f dB", parameter.value)).font(.system(size: 8, weight: .medium, design: .monospaced)).foregroundStyle(.gray)
    }
    private var declipButton: some View {
        let parameter: ObservableAUParameter = parameterTree.global.declip
        return Button { parameter.value = parameter.value >= 0.5 ? 0 : 1 } label: {
            Text(parameter.value >= 0.5 ? "削波修复" : "修复关闭").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(parameter.value >= 0.5 ? Color(white: 0.13) : .gray)
                .frame(width: 139, height: 50).background(parameter.value >= 0.5 ? repairTint : Color(white: 0.18), in: RepairTop())
        }.buttonStyle(.plain).accessibilityLabel("削波修复").accessibilityValue(parameter.value >= 0.5 ? "开启" : "关闭")
    }
    private func typeButton(_ value: Float, label: String) -> some View {
        let parameter: ObservableAUParameter = parameterTree.global.processingType
        let selected = parameter.value.rounded() == value
        return Button { parameter.value = value } label: {
            Text(label).font(.system(size: 19, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selected ? Color(white: 0.13) : .gray)
                .background(selected ? repairTint : .black)
                .clipShape(RepairQuarter(left: value == 0))
                .overlay(RepairQuarter(left: value == 0).stroke(selected ? repairTint : .gray, lineWidth: 1.5))
        }.buttonStyle(.plain).help("处理类型" + label)
    }
    private func qualityButton(_ value: Float, label: String) -> some View {
        let parameter: ObservableAUParameter = parameterTree.global.quality
        return Button { parameter.value = value } label: {
            Text(label).font(.system(size: 11, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(parameter.value.rounded() == value ? .white : Color(white: 0.13))
                .background(parameter.value.rounded() == value ? repairTint : .clear)
        }.buttonStyle(.plain).help(value == 0 ? "适合 FCP 日常剪辑" : "高质量计算量较大，建议离线处理或预先渲染")
    }
    private func selectSlot(_ useA: Bool) {
        guard useA != slotA else { return }
        if slotA { a = effectParameterSnapshot(audioUnit) } else { b = effectParameterSnapshot(audioUnit) }
        applyEffectParameters(useA ? a : b, to: audioUnit); slotA = useA
    }
    private var helpContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("破音修复使用说明").font(.headline)
            Text("开启中央削波修复，选择处理类型一或二，试听声音并比较伪影。左侧滑杆调整输出增益，A/B 可以保存两组参数快速对照。")
            Text("标准质量用于 FCP 日常剪辑。高质量计算量较大，建议离线处理或预先渲染；高采样率、重度削波时可能超过实时播放预算。两种质量保持相同的宿主补偿延迟。")
            Text("该效果重建削波丢失的波形；重度失真不能保证完全恢复。保存预设仅用于此效果。")
        }.font(.callout).padding(22).frame(width: 320)
    }
}

private struct RepairTop: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path(); p.move(to: CGPoint(x: 3, y: rect.height))
        p.addCurve(to: CGPoint(x: rect.width - 3, y: rect.height), control1: CGPoint(x: 13, y: -17), control2: CGPoint(x: rect.width - 13, y: -17))
        p.closeSubpath(); return p
    }
}
private struct RepairQuarter: Shape {
    let left: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if left {
            p.move(to: .zero); p.addLine(to: CGPoint(x: r.width, y: 0)); p.addLine(to: CGPoint(x: r.width, y: r.height))
            p.addQuadCurve(to: .zero, control: CGPoint(x: 14, y: r.height - 5))
        } else {
            p.move(to: .zero); p.addLine(to: CGPoint(x: r.width, y: 0))
            p.addQuadCurve(to: CGPoint(x: 0, y: r.height), control: CGPoint(x: r.width - 14, y: r.height - 5)); p.closeSubpath()
        }
        return p
    }
}
private struct RepairFooter: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path(); p.move(to: .zero)
        p.addCurve(to: CGPoint(x: r.width, y: 0), control1: CGPoint(x: 160, y: 0), control2: CGPoint(x: 90, y: 34))
        p.addLine(to: CGPoint(x: r.width, y: r.height)); p.addLine(to: CGPoint(x: 0, y: r.height)); p.closeSubpath(); return p
    }
}

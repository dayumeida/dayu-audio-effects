import SwiftUI
import UniformTypeIdentifiers

let effectPanelTint = Color(red: 0.78, green: 0.88, blue: 0.87)

enum EffectPanelAssets {
    #if os(macOS)
    static let images: [String: NSImage] = {
        let bundle = Bundle(for: _______ExtensionAudioUnit.self)
        var result: [String: NSImage] = [:]
        for name in ["background", "display", "display-small", "largeknob", "smallknob", "slider-button-on", "slider-empty", "slider-filled", "levelbar_on", "levelbar_off"] {
            if let url = bundle.url(forResource: "Denoise-" + name, withExtension: "tiff") {
                result[name] = NSImage(contentsOf: url)
            }
        }
        return result
    }()
    static func image(_ name: String) -> Image { Image(nsImage: images[name] ?? NSImage()) }
    #else
    static let images: [String: UIImage] = {
        let bundle = Bundle(for: _______ExtensionAudioUnit.self)
        var result: [String: UIImage] = [:]
        for name in ["background", "display", "display-small", "largeknob", "smallknob", "slider-button-on", "slider-empty", "slider-filled", "levelbar_on", "levelbar_off"] {
            if let url = bundle.url(forResource: "Denoise-" + name, withExtension: "tiff") { result[name] = UIImage(contentsOfFile: url.path) }
        }
        return result
    }()
    static func image(_ name: String) -> Image { Image(uiImage: images[name] ?? UIImage()) }
    #endif
}

struct EffectParameterReadout: View {
    @State var parameter: ObservableAUParameter
    var small = false
    var body: some View {
        TextField(parameter.displayName, value: $parameter.value,
                  format: .number.precision(.fractionLength(parameter.unit == .percent ? 0 : 1)))
            .textFieldStyle(.plain).multilineTextAlignment(.center)
            .font(.system(size: small ? 10 : 13, design: .monospaced))
            .foregroundStyle(effectPanelTint)
            .frame(width: small ? 40 : 56, height: small ? 18 : 28)
            .background(EffectPanelAssets.image(small ? "display-small" : "display").resizable())
            .onSubmit { parameter.value = min(parameter.max, max(parameter.min, parameter.value)) }
            .accessibilityLabel(parameter.displayName)
    }
}

struct EffectParameterKnob: View {
    @State var parameter: ObservableAUParameter
    var small = false
    @State private var start: Float?
    private var fraction: Double { Double((parameter.value - parameter.min) / (parameter.max - parameter.min)) }
    var body: some View {
        ZStack {
            EffectPanelAssets.image(small ? "smallknob" : "largeknob").resizable()
            ForEach(0 ..< 29, id: \.self) { index in
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Double(index) / 28 <= fraction ? Color(red: 1, green: 0.67, blue: 0.63) : .white.opacity(0.10))
                    .frame(width: small ? 2.5 : 4.8, height: small ? 2 : 3.8)
                    .offset(y: small ? -30 : -61)
                    .rotationEffect(.degrees(-140 + Double(index) * 10))
                    .position(x: small ? 36 : 64, y: small ? 36 : 84)
            }
            Capsule().fill(effectPanelTint).frame(width: 2, height: small ? 7 : 13)
                .offset(y: small ? -21 : -43)
                .rotationEffect(.degrees(-140 + fraction * 280))
                .position(x: small ? 36 : 64, y: small ? 36 : 84)
        }
        .frame(width: small ? 72 : 128, height: small ? 72 : 168)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            if start == nil { start = parameter.value; parameter.onEditingChanged(true) }
            let delta = Float(value.translation.height) * (parameter.max - parameter.min) / 160
            parameter.value = min(parameter.max, max(parameter.min, (start ?? parameter.value) - delta))
        }.onEnded { _ in start = nil; parameter.onEditingChanged(false) })
        .accessibilityLabel(parameter.displayName)
        .accessibilityValue(String(format: "%.0f %%", parameter.value))
        .accessibilityAdjustableAction { direction in
            parameter.value = min(parameter.max, max(parameter.min, parameter.value + (direction == .increment ? 1 : -1)))
        }
    }
}

struct EffectVerticalSlider: View {
    @State var parameter: ObservableAUParameter
    var tint = effectPanelTint
    var textured = true
    @State private var editing = false
    var body: some View {
        GeometryReader { geometry in
            let fraction = CGFloat((parameter.value - parameter.min) / (parameter.max - parameter.min))
            ZStack(alignment: .bottom) {
                if textured {
                    EffectPanelAssets.image("slider-empty").resizable().frame(width: 10)
                    EffectPanelAssets.image("slider-filled").resizable().frame(width: 10)
                        .mask(alignment: .bottom) { Rectangle().frame(height: geometry.size.height * fraction) }
                    EffectPanelAssets.image("slider-button-on").resizable().frame(width: 26, height: 44)
                        .position(x: geometry.size.width / 2, y: (1 - fraction) * (geometry.size.height - 30) + 15)
                } else {
                    Rectangle().fill(.gray.opacity(0.3)).frame(width: 3)
                    Rectangle().fill(tint).frame(width: 3, height: geometry.size.height * fraction)
                    Circle().fill(Color(white: 0.13)).overlay(Circle().stroke(tint, lineWidth: 4))
                        .frame(width: 15, height: 15).position(x: geometry.size.width / 2, y: (1 - fraction) * geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                if !editing { editing = true; parameter.onEditingChanged(true) }
                let padding: CGFloat = textured ? 15 : 0
                let v = 1 - min(1, max(0, (gesture.location.y - padding) / (geometry.size.height - 2 * padding)))
                parameter.value = parameter.min + Float(v) * (parameter.max - parameter.min)
            }.onEnded { _ in editing = false; parameter.onEditingChanged(false) })
            .accessibilityLabel(parameter.displayName)
            .accessibilityValue(String(format: "%.1f dB", parameter.value))
            .accessibilityAdjustableAction { direction in
                parameter.value = min(parameter.max, max(parameter.min, parameter.value + (direction == .increment ? 1 : -1)))
            }
        }
    }
}

struct EffectWaveform: View {
    let before: [Float]
    let after: [Float]
    var body: some View {
        Canvas { context, size in
            let center = size.height / 2
            for (values, color) in [(before, effectPanelTint.opacity(0.4)), (after, Color.white.opacity(0.8))] {
                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * size.width / CGFloat(max(1, values.count - 1))
                    let h = CGFloat(min(1, max(0, v))) * (center - 3)
                    path.move(to: CGPoint(x: x, y: center - h)); path.addLine(to: CGPoint(x: x, y: center + h))
                }
                context.stroke(path, with: .color(color), lineWidth: 0.8)
            }
            var line = Path(); line.move(to: CGPoint(x: 0, y: center)); line.addLine(to: CGPoint(x: size.width, y: center))
            context.stroke(line, with: .color(effectPanelTint), style: StrokeStyle(lineWidth: 1.3, dash: [1, 3]))
        }.accessibilityLabel("实时波形：蓝灰为输入，白色为处理后")
    }
}

struct EffectPreset: Codable {
    var format = "dayu-effect"
    var version = 1
    let effect: String
    let parameters: [String: Float]
}
struct EffectPresetDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var preset: EffectPreset
    init(effect: String = "", parameters: [String: Float] = [:]) { preset = EffectPreset(effect: effect, parameters: parameters) }
    init(configuration: ReadConfiguration) throws {
        preset = try JSONDecoder().decode(EffectPreset.self, from: configuration.file.regularFileContents ?? Data())
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try encoder.encode(preset))
    }
}

func effectParameterSnapshot(_ unit: _______ExtensionAudioUnit) -> [String: Float] {
    Dictionary(uniqueKeysWithValues: (unit.parameterTree?.allParameters ?? [])
        .filter { $0.flags.contains(.flag_IsWritable) }.map { ($0.identifier, $0.value) })
}
func applyEffectParameters(_ values: [String: Float], to unit: _______ExtensionAudioUnit) {
    for parameter in unit.parameterTree?.allParameters ?? [] where parameter.flags.contains(.flag_IsWritable) {
        if let value = values[parameter.identifier], value.isFinite { parameter.value = min(parameter.maxValue, max(parameter.minValue, value)) }
    }
}
func resetEffectParameters(_ unit: _______ExtensionAudioUnit) {
    let defaults = unit.defaultParameterValues
    for parameter in unit.parameterTree?.allParameters ?? [] where parameter.flags.contains(.flag_IsWritable) {
        if Int(parameter.address) < defaults.count { parameter.value = defaults[Int(parameter.address)] }
    }
}
func loadEffectPreset(_ result: Result<URL, Error>, into unit: _______ExtensionAudioUnit) -> String {
    do {
        let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let preset = try JSONDecoder().decode(EffectPreset.self, from: Data(contentsOf: url))
        guard preset.format == "dayu-effect", preset.version == 1, preset.effect == unit.effectKind.rawValue else {
            throw NSError(domain: "DayuPreset", code: 1, userInfo: [NSLocalizedDescriptionKey: "预设不属于当前效果器或版本不受支持。"])
        }
        applyEffectParameters(preset.parameters, to: unit)
        return "已载入：\(url.lastPathComponent)"
    } catch { return "载入失败：\(error.localizedDescription)" }
}

import SwiftUI

struct ParameterSlider: View {
    @State var param: ObservableAUParameter
    var detail: String? = nil

    private var formattedValue: String {
        switch param.unit {
        case .milliseconds: return String(format: "%.0f ms", param.value)
        case .percent: return String(format: "%.0f %%", param.value)
        default: return String(format: "%.1f dB", param.value)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(param.displayName).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(formattedValue).font(.system(size: 12, design: .monospaced)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $param.value, in: param.min ... param.max, onEditingChanged: param.onEditingChanged)
                .accessibilityLabel(param.displayName)
                .accessibilityValue(formattedValue)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(9)
    }
}

import Foundation

// Shared by the container and AU extension. A component's identity never changes
// while it is loaded; each effect owns its parameter schema and latency contract.
nonisolated enum DayuEffectKind: String, CaseIterable, Identifiable, Sendable {
    case referenceLeveler = "reference"
    case realtimeLeveler = "low-latency"
    case audioDenoise = "audio-denoise-ai"
    case era5Declipper = "era5-declipper"

    var id: String { rawValue }
    var subtype: UInt32 {
        switch self {
        case .referenceLeveler: 0x64796c76 // dylv: keep existing FCP projects compatible
        case .realtimeLeveler: 0x64796c6c // dyll
        case .audioDenoise: 0x6479646e // dydn
        case .era5Declipper: 0x64796372 // dycr
        }
    }
    var subtypeString: String {
        switch self {
        case .referenceLeveler: "dylv"
        case .realtimeLeveler: "dyll"
        case .audioDenoise: "dydn"
        case .era5Declipper: "dycr"
        }
    }
    var title: String {
        switch self {
        case .referenceLeveler: "大鱼自动电平"
        case .realtimeLeveler: "大鱼自动电平·低延迟"
        case .audioDenoise: "大鱼智能降噪"
        case .era5Declipper: "大鱼破音修复"
        }
    }
    var stateParameterKey: String {
        switch self {
        case .referenceLeveler, .realtimeLeveler: "dayuLevelerParameters"
        case .audioDenoise: "dayuDenoiseParameters"
        case .era5Declipper: "dayuDeclipperParameters"
        }
    }
    var minimumSampleRate: Double { self == .era5Declipper ? 16_000 : 8_000 }
    init?(subtype: UInt32) {
        guard let kind = Self.allCases.first(where: { $0.subtype == subtype }) else { return nil }
        self = kind
    }
}

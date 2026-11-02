import Foundation
import AudioToolbox

func dayuParameterSpecs(for kind: DayuEffectKind, defaults: [Float]) -> ParameterTreeSpec {
    switch kind {
    case .referenceLeveler:
        return ParameterTreeSpec {
            ParameterGroupSpec(identifier: "global", name: "自动电平") {
                ParameterSpec(address: .targetLevel, identifier: "targetLevel", name: "目标电平", units: .decibels, valueRange: -24 ... 0, defaultValue: defaults[0])
                ParameterSpec(address: .amount, identifier: "amount", name: "调整强度", units: .percent, valueRange: 0 ... 100, defaultValue: defaults[1])
                ParameterSpec(address: .maxBoost, identifier: "maxBoost", name: "最大提升", units: .decibels, valueRange: 0 ... 30, defaultValue: defaults[2])
                ParameterSpec(address: .response, identifier: "response", name: "最短分段", units: .milliseconds, valueRange: 100 ... 2000, defaultValue: defaults[3])
                ParameterSpec(address: .noiseFloor, identifier: "noiseFloor", name: "活动门槛", units: .decibels, valueRange: -80 ... -20, defaultValue: defaults[4])
                ParameterSpec(address: .outputGain, identifier: "outputGain", name: "输出增益", units: .decibels, valueRange: -12 ... 12, defaultValue: defaults[5])
                ParameterSpec(address: .ceiling, identifier: "ceiling", name: "附加峰值保护", units: .decibels, valueRange: -12 ... 0, defaultValue: defaults[6])
            }
        }

    case .realtimeLeveler:
        return ParameterTreeSpec {
            ParameterGroupSpec(identifier: "global", name: "低延迟自动电平") {
                ParameterSpec(address: .targetLevel, identifier: "targetLevel", name: "目标 RMS", units: .decibels, valueRange: -30 ... -3, defaultValue: defaults[0])
                ParameterSpec(address: .amount, identifier: "amount", name: "调整强度", units: .percent, valueRange: 0 ... 100, defaultValue: defaults[1])
                ParameterSpec(address: .maxBoost, identifier: "maxBoost", name: "最大提升", units: .decibels, valueRange: 0 ... 24, defaultValue: defaults[2])
                ParameterSpec(address: .response, identifier: "response", name: "响应时间", units: .milliseconds, valueRange: 100 ... 2000, defaultValue: defaults[3])
                ParameterSpec(address: .noiseFloor, identifier: "noiseFloor", name: "活动门槛", units: .decibels, valueRange: -80 ... -30, defaultValue: defaults[4])
                ParameterSpec(address: .outputGain, identifier: "outputGain", name: "输出增益", units: .decibels, valueRange: -12 ... 12, defaultValue: defaults[5])
                ParameterSpec(address: .ceiling, identifier: "ceiling", name: "峰值上限", units: .decibels, valueRange: -12 ... 0, defaultValue: defaults[6])
            }
        }
    case .audioDenoise:
        return ParameterTreeSpec {
            ParameterGroupSpec(identifier: "global", name: "智能降噪") {
                ParameterSpec(address: UInt64(1), identifier: "active", name: "启用处理", units: .boolean, valueRange: 0 ... 1, defaultValue: defaults[1])
                ParameterSpec(address: UInt64(2), identifier: "strength", name: "降噪强度", units: .percent, valueRange: 0 ... 100, defaultValue: defaults[2])
                ParameterSpec(address: UInt64(3), identifier: "outputGain", name: "输出增益", units: .decibels, valueRange: -24 ... 24, defaultValue: defaults[3])
                ParameterSpec(address: UInt64(4), identifier: "low", name: "低频处理", units: .percent, valueRange: 0 ... 100, defaultValue: defaults[4])
                ParameterSpec(address: UInt64(5), identifier: "mid", name: "中频处理", units: .percent, valueRange: 0 ... 100, defaultValue: defaults[5])
                ParameterSpec(address: UInt64(6), identifier: "high", name: "高频处理", units: .percent, valueRange: 0 ... 100, defaultValue: defaults[6])
                ParameterSpec(address: UInt64(7), identifier: "analyzing", name: "分析状态", units: .percent, valueRange: 0 ... 100, defaultValue: 0, flags: [.flag_IsReadable])
            }
        }

    case .era5Declipper:
        return ParameterTreeSpec {
            ParameterGroupSpec(identifier: "global", name: "破音修复") {
                ParameterSpec(address: UInt64(0), identifier: "quality", name: "处理质量", units: .indexed, valueRange: 0 ... 1, defaultValue: defaults[0], valueStrings: ["标准", "高质量"])
                ParameterSpec(address: UInt64(1), identifier: "active", name: "启用处理", units: .boolean, valueRange: 0 ... 1, defaultValue: defaults[1])
                ParameterSpec(address: UInt64(2), identifier: "processingType", name: "处理类型", units: .indexed, valueRange: 0 ... 1, defaultValue: defaults[2], valueStrings: ["类型一", "类型二"])
                ParameterSpec(address: UInt64(3), identifier: "outputGain", name: "输出增益", units: .decibels, valueRange: -30 ... 5, defaultValue: defaults[3])
                ParameterSpec(address: UInt64(4), identifier: "declip", name: "削波修复", units: .boolean, valueRange: 0 ... 1, defaultValue: defaults[4])
            }
        }

    }
}

extension ParameterSpec {
    init(
        address: _______ExtensionParameterAddress,
        identifier: String,
        name: String,
        units: AudioUnitParameterUnit,
        valueRange: ClosedRange<AUValue>,
        defaultValue: AUValue,
        unitName: String? = nil,
        flags: AudioUnitParameterOptions = [AudioUnitParameterOptions.flag_IsWritable, AudioUnitParameterOptions.flag_IsReadable],
        valueStrings: [String]? = nil,
        dependentParameters: [NSNumber]? = nil
    ) {
        self.init(address: address.rawValue,
                  identifier: identifier,
                  name: name,
                  units: units,
                  valueRange: valueRange,
                  defaultValue: defaultValue,
                  unitName: unitName,
                  flags: flags,
                  valueStrings: valueStrings,
                  dependentParameters: dependentParameters)
    }
}

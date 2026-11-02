import SwiftUI

// Exhaustive routing keeps a newly registered effect from inheriting another UI.
struct DayuEffectView: View {
    let parameterTree: ObservableAUParameterGroup
    let audioUnit: _______ExtensionAudioUnit
    var onResize: ((CGSize) -> Void)? = nil

    @ViewBuilder var body: some View {
        switch audioUnit.effectKind {
        case .referenceLeveler, .realtimeLeveler:
            _______ExtensionMainView(parameterTree: parameterTree, audioUnit: audioUnit)
        case .audioDenoise:
            DenoiseMainView(parameterTree: parameterTree, audioUnit: audioUnit)
        case .era5Declipper:
            DeclipMainView(parameterTree: parameterTree, audioUnit: audioUnit, onResize: onResize)
        }
    }
}

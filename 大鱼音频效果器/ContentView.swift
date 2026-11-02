import AudioToolbox
import SwiftUI

struct ContentView: View {
    let hostModel: AudioUnitHostModel
    @State private var isSheetPresented = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                Picker("效果器", selection: Binding(get: { hostModel.selectedEffect }, set: { hostModel.selectEffect($0) })) {
                    ForEach(DayuEffectKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.menu).padding(.horizontal, 24)
                .disabled(hostModel.offlineProcessing.isProcessing)

                if hostModel.audioUnitCrashed {
                    Text("\(hostModel.viewModel.title) 已中断")
                    Button("重新加载效果器") { hostModel.selectEffect(hostModel.selectedEffect) }
                    Spacer()
                } else if let controller = hostModel.viewModel.viewController {
                    AUViewControllerUI(viewController: controller)
                        .id(hostModel.selectedEffect)
                        .allowsHitTesting(!hostModel.offlineProcessing.isProcessing)
                } else {
                    ProgressView()
                    Text(hostModel.viewModel.message).foregroundStyle(.secondary)
                    Spacer()
                }
                ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                Label("在右侧导入素材，调整参数后预览并输出", systemImage: "waveform")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
            .padding(.vertical, 16).frame(minWidth: 520, idealWidth: 560, maxWidth: 600)
            Divider()
            OfflineProcessingView(hostModel: hostModel).frame(minWidth: 420, maxWidth: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 760)
    }
}

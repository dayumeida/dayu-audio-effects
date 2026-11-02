import SwiftUI

extension Notification.Name {
    static let dayuOpenAudio = Notification.Name("media.dayu.openAudio")
    static let dayuProcessMedia = Notification.Name("media.dayu.processMedia")
}

@main
struct _______App: App {
    private let hostModel = AudioUnitHostModel()

    var body: some Scene {
        WindowGroup("大鱼音频效果器") {
            ContentView(hostModel: hostModel)
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 840)
        #endif
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("导入音频或视频…") { NotificationCenter.default.post(name: .dayuProcessMedia, object: nil) }
                    .keyboardShortcut("o")
                    .disabled(hostModel.isLoading || hostModel.offlineProcessing.isProcessing)
                Button("输出副本") { hostModel.exportMedia() }
                    .keyboardShortcut("e")
                    .disabled(!hostModel.canExport)
            }
            CommandMenu("效果器") {
                ForEach(DayuEffectKind.allCases) { kind in
                    Button { hostModel.selectEffect(kind) } label: {
                        if hostModel.selectedEffect == kind { Label(kind.title, systemImage: "checkmark") }
                        else { Text(kind.title) }
                    }
                    .disabled(hostModel.offlineProcessing.isProcessing)
                }
                Divider()
                Button(hostModel.isPlaying ? "停止试听" : "播放试听") {
                    hostModel.isPlaying ? hostModel.stopPlaying() : hostModel.startPlaying()
                }.keyboardShortcut(.space, modifiers: []).disabled(hostModel.isLoading || hostModel.offlineProcessing.isProcessing || hostModel.mediaPreview.source == nil)
            }
        }
    }
}

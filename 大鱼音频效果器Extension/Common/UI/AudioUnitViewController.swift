import CoreAudioKit
import SwiftUI

@MainActor
public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {
    private var audioUnit: _______ExtensionAudioUnit?
    private var hostingController: HostingController<DayuEffectView>?

    public override func viewDidLoad() {
        super.viewDidLoad()
        configureSwiftUIView()
    }

    // Audio Unit creation is independent of UI creation; hosts may instantiate on any thread.
    nonisolated public func createAudioUnit(with description: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try _______ExtensionAudioUnit(componentDescription: description, options: [])
        Task { @MainActor [weak self] in
            self?.audioUnit = unit
            self?.configureSwiftUIView()
        }
        return unit
    }

    private func configureSwiftUIView() {
        guard isViewLoaded, let audioUnit, hostingController == nil,
              let parameters = audioUnit.observableParameterTree else { return }
        let content = DayuEffectView(parameterTree: parameters, audioUnit: audioUnit, onResize: { [weak self] size in
            self?.preferredContentSize = size
        })
        let host = HostingController(rootView: content)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        hostingController = host
        switch audioUnit.effectKind {
        case .audioDenoise: preferredContentSize = CGSize(width: 450, height: 640)
        case .era5Declipper: preferredContentSize = CGSize(width: 400, height: 620)
        case .referenceLeveler, .realtimeLeveler: preferredContentSize = CGSize(width: 600, height: 660)
        }
    }
}

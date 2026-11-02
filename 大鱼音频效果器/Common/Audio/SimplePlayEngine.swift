//
//  SimplePlayEngine.swift
//  大鱼音频效果器
//
//  Created by dayu on 2026/11/1.
//

import Foundation
import CoreAudioKit
import AVFoundation
@preconcurrency import AVFAudio

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Wraps and Audio Unit extension and provides helper functions.
extension AVAudioUnit {

    var wantsAudioInput: Bool {
        let componentType = self.auAudioUnit.componentDescription.componentType
        return componentType == kAudioUnitType_MusicEffect || componentType == kAudioUnitType_Effect
    }
    
    static fileprivate func findComponent(type: String, subType: String, manufacturer: String) -> AVAudioUnitComponent? {
        // Make a component description matching any Audio Unit of the selected component type.
        let description = AudioComponentDescription(componentType: type.fourCharCode!,
                                                    componentSubType: subType.fourCharCode!,
                                                    componentManufacturer: manufacturer.fourCharCode!,
                                                    componentFlags: 0,
                                                    componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: description).first
    }
    
	fileprivate func loadAudioUnitViewController() async -> ViewController? {
		let viewController = await auAudioUnit.requestViewController()

		if #available(macOS 13.0, iOS 16.0, *) {
			if viewController == nil {
				let genericViewController = AUGenericViewController()
				await MainActor.run {
					genericViewController.auAudioUnit = self.auAudioUnit
				}
				return genericViewController
			}
		}

		return viewController
	}
}

/// Manages the interaction with the AudioToolbox and AVFoundation frameworks.
@MainActor
@Observable
public class SimplePlayEngine {
    
    var avAudioUnit: AVAudioUnit?
    private var componentLoadGeneration = 0
    
    // Synchronizes starting/stopping the engine and scheduling file segments.
    private let stateChangeQueue = DispatchQueue(label: "com.example.apple-samplecode.StateChangeQueue")
    
    // Playback engine.
    private let engine = AVAudioEngine()
    
    // Engine's player node.
    private let player = AVAudioPlayerNode()
    
    // File to play.
    private var file: AVAudioFile?
    private var scopedFileURL: URL?
    public private(set) var audioFileName = "Synth.aif"
    
    // Whether we are playing.
    private(set) var isPlaying = false
    public private(set) var playbackError: String?
    
    // This block will be called every render cycle and will receive MIDI events
    private let midiOutBlock: AUMIDIOutputEventBlock = { sampleTime, cable, length, data in return noErr }
    
    // This block can be used to send MIDI UMP events to the Audio Unit
    var scheduleMIDIEventListBlock: AUMIDIEventListBlock? = nil
    
    // MARK: Initialization
    
    public init() {
        engine.attach(player)
        
        guard let fileURL = Bundle.main.url(forResource: "Synth", withExtension: "aif") else {
            fatalError("\"Synth.aif\" file not found.")
        }
        setPlayerFile(fileURL)
        
        engine.prepare()
    }
    
    private func setupMIDI() {
        if !MIDIManager.shared.setupPort(midiProtocol: MIDIProtocolID._2_0, receiveBlock: { [weak self] eventList, _ in
            if let scheduleMIDIEventListBlock = self?.scheduleMIDIEventListBlock {
                _ = scheduleMIDIEventListBlock(AUEventSampleTimeImmediate, 0, eventList)
            }
        }) {
            fatalError("Failed to setup Core MIDI")
        }
    }
    
    func initComponent(type: String, subType: String, manufacturer: String) async -> ViewController? {
        // Reset the engine to remove any configured audio units.
        reset()
        let generation = componentLoadGeneration
        playbackError = nil
        guard !Task.isCancelled else { return nil }
        guard let component = AVAudioUnit.findComponent(type: type, subType: subType, manufacturer: manufacturer) else {
            playbackError = "未找到效果器（\(subType)）。请从最新构建打开主应用以注册扩展。"
            return nil
        }
        
        // Instantiate the audio unit.
        do {
            let audioUnit = try await AVAudioUnit.instantiate(
                with: component.audioComponentDescription, options: AudioComponentInstantiationOptions.loadOutOfProcess)
            
            guard !Task.isCancelled, generation == componentLoadGeneration else { return nil }
            self.connect(avAudioUnit: audioUnit)
            let controller = await audioUnit.loadAudioUnitViewController()
            guard !Task.isCancelled, generation == componentLoadGeneration else { return nil }
            return controller
        } catch {
            if generation == componentLoadGeneration { playbackError = "无法加载效果器：\(error.localizedDescription)" }
            return nil
        }
    }
    
    private func setPlayerFile(_ fileURL: URL) {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            self.file = file
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        } catch {
            fatalError("Could not create AVAudioFile instance. error: \(error).")
        }
    }
    
    public func loadAudioFile(_ url: URL) throws {
        let accessed = url.startAccessingSecurityScopedResource()
        let newFile: AVAudioFile
        do {
            newFile = try AVAudioFile(forReading: url)
            guard (1 ... 2).contains(newFile.processingFormat.channelCount) else {
                throw NSError(domain: "DayuLeveler", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "请选择单声道或立体声音频文件。"])
            }
        } catch {
            if accessed { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        let resume = isPlaying
        stopPlaying()
        let previous = scopedFileURL
        file = newFile
        scopedFileURL = accessed ? url : nil
        audioFileName = url.lastPathComponent
        connect(avAudioUnit: avAudioUnit)
        previous?.stopAccessingSecurityScopedResource()
        engine.prepare()
        if resume { startPlaying() }
    }

    private func setSessionActive(_ active: Bool) {
#if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(active)
        } catch {
            fatalError("Could not set Audio Session active \(active). error: \(error).")
        }
#endif
    }
    
    // MARK: Playback State
    
    public func startPlaying() {
        stateChangeQueue.sync {
            if !self.isPlaying { self.startPlayingInternal() }
        }
    }
    
    public func stopPlaying() {
        stateChangeQueue.sync {
            if self.isPlaying { self.stopPlayingInternal() }
        }
    }
    
    public func togglePlay() -> Bool {
        if isPlaying {
            stopPlaying()
        } else {
            startPlaying()
        }
        return isPlaying
    }
    
    private func startPlayingInternal() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        playbackError = nil
        // The UI controls playback on the main actor.
        setSessionActive(true)
        
        if avAudioUnit.wantsAudioInput {
            // Schedule buffers on the player.
            scheduleEffectLoop()
        }
        
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        
        // Start the engine.
        do {
            try engine.start()
        } catch {
            isPlaying = false
            playbackError = "无法启动音频引擎：\(error.localizedDescription)"
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            guard engine.isRunning else {
                playbackError = "音频引擎未运行，请重新打开应用后重试。"
                return
            }
            do {
                if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) { try player.playAudio() }
                else { player.play() }
            } catch {
                playbackError = "无法播放音频：\(error.localizedDescription)"
                engine.stop()
                return
            }
        }
        
        isPlaying = true
    }
    
    private func stopPlayingInternal() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            player.stop()
        }
        engine.stop()
        isPlaying = false
        setSessionActive(false)
    }
    
    private func scheduleEffectLoop() {
        guard let file else { return }
        player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPlaying else { return }
                self.scheduleEffectLoop()
            }
        }
    }

    private func resetAudioLoop() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            // Connect player -> mixer.
            guard let format = file?.processingFormat else { fatalError("No AVAudioFile defined (processing format unavailable).") }
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }
    
    public func reset() {
        componentLoadGeneration += 1
        stopPlaying()
        connect(avAudioUnit: nil)
    }
    
    public func connect(avAudioUnit newUnit: AVAudioUnit?, completion: @escaping (() -> Void) = {}) {
        let wasPlaying = isPlaying
        stopPlaying()
        engine.stop()
        player.stop()
        engine.disconnectNodeInput(engine.mainMixerNode)
        engine.disconnectNodeOutput(player)
        if let previous = self.avAudioUnit {
            engine.disconnectNodeOutput(previous)
            engine.detach(previous)
        }
        self.avAudioUnit = newUnit
        scheduleMIDIEventListBlock = nil

        if let newUnit {
            engine.attach(newUnit)
            if newUnit.wantsAudioInput, let format = file?.processingFormat {
                engine.connect(player, to: newUnit, format: format)
                engine.connect(newUnit, to: engine.mainMixerNode, format: format)
            } else {
                let rate = engine.outputNode.outputFormat(forBus: 0).sampleRate
                engine.connect(newUnit, to: engine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
            }
            scheduleMIDIEventListBlock = newUnit.auAudioUnit.scheduleMIDIEventListBlock
        } else if let format = file?.processingFormat {
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        engine.prepare()
        if wasPlaying { startPlaying() }
        completion()
    }
}

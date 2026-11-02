//
//  AudioUnitViewModel.swift
//  大鱼音频效果器
//
//  Created by dayu on 2026/11/1.
//

import SwiftUI
import AudioToolbox
import CoreAudioKit

struct AudioUnitViewModel {
    var showAudioControls: Bool = false
    var showMIDIContols: Bool = false
    var title: String = "大鱼自动电平"
    var message: String = "正在加载音频插件…"
    var viewController: ViewController?
}

//
//  ValidationView.swift
//  大鱼音频效果器
//
//  Created by dayu on 2026/11/1.
//

import SwiftUI
import AudioToolbox

struct ValidationView: View {
    var hostModel: AudioUnitHostModel
    @Binding var isSheetPresented: Bool
    
    
    var body: some View {
        if let validationResult = hostModel.validationResult {
            Text(validationResult == .passed ? "验证通过" : "验证未通过")
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(validationResult == .passed ? Color.green : Color.red)
                )
                .foregroundColor(.black)
                .onTapGesture {
                    isSheetPresented.toggle()
                }
                .sheet(isPresented: $isSheetPresented) {
                    VStack {
                        Text("关闭")
                            .padding(4)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.gray.opacity(0.2))
                            )
                            .foregroundColor(.primary)
                            .onTapGesture {
                                isSheetPresented.toggle()
                            }
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                if let output = hostModel.currentValidationData {
                                    Text(output)
                                        .foregroundColor(.primary)
                                        .background(Color.gray.opacity(0.1))
                                        .cornerRadius(8)
                                        .lineLimit(nil)
                                        .frame(maxWidth: .infinity)
                                        .textSelection(.enabled)
                                } else {
                                    Text("验证过程可能已中断")
                                }
                            }
                            .padding()
                        }
                    }
                    .padding()
                }
        }
    }
}

// MockChannelSink.swift
// 测试用 ChannelSink 实现 — 记录所有通道调用 + 调用顺序
//
// 责任：
//   - 记录 playExpression / playAction / playAudio 全部调用
//   - 记录 lastOrder（验证通道优先级：expression < action < audio）
//   - 提供 reset() 让 test 之间清理状态
//
// 共享：所有 test 文件都用它，import @testable import PetProfileRuntime

import Foundation
@testable import PetProfileRuntime

final class MockChannelSink: ChannelSink {
    /// 每次 playExpression 调用的 state
    var expressionCalls: [VisualState] = []
    /// 每次 playAction 调用的 reaction
    var actionCalls: [ActionReaction] = []
    /// 每次 playAudio 调用的 catchphrase text（nil 不记录）
    var audioCalls: [String] = []
    /// 每次 playAudio(nil) 也算一次 "audio was considered but skipped"
    var audioNilCount: Int = 0
    /// 所有 sink 调用的 channel kind 顺序（用于验证 priority）
    private(set) var lastOrder: [ChannelKind] = []

    func playExpression(_ state: VisualState) {
        expressionCalls.append(state)
        lastOrder.append(.expression)
    }

    func playAction(_ reaction: ActionReaction) {
        actionCalls.append(reaction)
        lastOrder.append(.action)
    }

    func playAudio(_ catchphrase: AudioCatchphrase?) {
        if let cp = catchphrase {
            audioCalls.append(cp.text)
        } else {
            audioNilCount += 1
        }
        lastOrder.append(.audio)
    }

    /// 清空所有记录（在 test 之间重置 mock 状态）
    func reset() {
        expressionCalls.removeAll()
        actionCalls.removeAll()
        audioCalls.removeAll()
        audioNilCount = 0
        lastOrder.removeAll()
    }
}

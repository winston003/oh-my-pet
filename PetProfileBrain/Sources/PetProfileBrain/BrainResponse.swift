// BrainResponse.swift
// Brain 解析 LLM output 后产出的结构化响应
//
// 设计要点：
//   - **expression: VisualState?** —— nil = 不切（保持 current state）
//   - **action: ActionReaction?** —— nil = 不触发 action reaction
//   - **audioCatchphrase: AudioCatchphrase?** —— nil = 不出声
//   - reply text 必填（没 text 的 LLM response 是 malformed）
//   - 不在这里塞"channel priority" / "dispatch order" —— 那是 ChannelDispatcher 的事
//

import Foundation
import PetProfile
import PetProfileRuntime

public struct BrainResponse: Equatable, Sendable {
    public let text: String
    /// 期望切到的 visual state。nil = 保持 current state 不变
    public let expression: VisualState?
    /// 期望触发的 action reaction。nil = 不动
    public let action: ActionReaction?
    /// 期望播放的 audio catchphrase。nil = 不出声
    public let audioCatchphrase: AudioCatchphrase?

    public init(
        text: String,
        expression: VisualState? = nil,
        action: ActionReaction? = nil,
        audioCatchphrase: AudioCatchphrase? = nil
    ) {
        self.text = text
        self.expression = expression
        self.action = action
        self.audioCatchphrase = audioCatchphrase
    }

    /// 是否完全空（除了 text 其它通道都 nil）
    public var isMinimal: Bool {
        return expression == nil && action == nil && audioCatchphrase == nil
    }
}

// SelectionPromptContext.swift
// SelectionPromptContext — Selection Assistant 用的 prompt 编排上下文
//
// 对应 spec §3.1 P7 "5 通道立体化"：把 pet 人设 + selectedText + action + appContext
// 拼成 provider 能直接消费的 system + user message 对。
//
// 跟 Brain.respond 的 PromptContext 区别：
//   - Brain.respond 的 PromptContext 是"驱动 pet 说话"（persona 通道全开、5 通道输出格式）
//   - 这里 SelectionPromptContext 是"selection tool"（短回复、人设轻注入、5 通道**不**开）
//
// 设计要点：
//   - struct + Sendable + Codable + Equatable
//   - 含 system + user + raw 字段（pet 名字 / 注入风格 / 完整 selectedText 原文）便于 debug
//   - **不**含 petID / model / providerID（那些属 TextCompletionRequest 的 metadata，
//     SelectionPromptContext 只是 prompt 编排结果）
//   - **不**含 AppContextSnapshot 原文（已经在 request 里了；避免重复）
//   - "honesty boundary"（spec P4）：system 段**必须**含 "Never claim to access" 之类的
//     边界声明。PromptBuilder 强制注入。
//
// 边界 / 不做：
//   - 不调 provider（属 provider 自己的 complete 路径）
//   - 不写盘（in-memory only；P2-N cache 单独管）
//   - 不做 token 计数（真 LLM 接入时再加）
//   - 不 import AppKit / SwiftUI（Core 层；UI 只看 String 字段）
//

import Foundation

/// Selection Assistant 的 prompt 编排输出。
/// system + user 是 LLM 实际要的两段；meta 字段是给 UI / debug 看的。
public struct SelectionPromptContext: Sendable, Codable, Equatable {
    /// system 段 — pet 人设 + 边界声明 + 长度约束
    public let system: String
    /// user 段 — action-specific 的指令 + selectedText + appName
    public let user: String
    /// 注入的 pet 名字（nil = 无 pet）；UI 在"human-readable summary"显示
    public let petName: String?
    /// 注入的 humor style 标签（如 "self-deprecating" / "gentle" / "sarcastic"）；
    /// UI 在 preview 框展示，让用户知道"现在是 Mitu 在说话"
    public let humorStyle: String?

    public init(
        system: String,
        user: String,
        petName: String? = nil,
        humorStyle: String? = nil
    ) {
        self.system = system
        self.user = user
        self.petName = petName
        self.humorStyle = humorStyle
    }
}

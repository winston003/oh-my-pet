// VisualState.swift
// Pet 视觉状态枚举 + 状态变化通知
//
// 5 个必选 state（与 expression pack 的 5 base state 对齐）+
// 通知名（PetPanel.setVisualState 投递时使用）
//
// 设计要点：
//   - 用 String raw value，跟 expression pack.states 的 key 保持一致（"idle" / "focus" / …）
//   - 状态机入口由 PetActionRouter 维护，PetPanel 不感知事件 → 状态映射
//   - 状态变化 notification: name = .petVisualStateChanged, userInfo["state"]: VisualState
//   - 旧 PetPanel.currentState: String 保留（不改 frozen 文件）；
//     新增的 setVisualState 扩展会调 switchVisualState 走原字段

import Foundation

/// Pet 当前展示的视觉 state。expression pack.states 的 5 base state 必有，
/// 跟 visual pack.states 是同构的（一个管脸、一个管身）。
public enum VisualState: String, Sendable, Equatable, Codable, CaseIterable, Hashable {
    case idle
    case focus
    case happy
    case tired
    case celebrate

    /// 从任意字符串解析（来自 PetPanel.currentState / expression pack 字段等）。
    /// 解析失败返回 nil（而不是默认 .idle），让调用方显式处理。
    public static func parse(_ raw: String) -> VisualState? {
        return VisualState(rawValue: raw)
    }
}

public extension Notification.Name {
    /// PetPanel 视觉状态切换时投递。userInfo:
    ///   - "state": VisualState（切换后的新 state）
    static let petVisualStateChanged = Notification.Name("PetProfileRuntime.petVisualStateChanged")
}

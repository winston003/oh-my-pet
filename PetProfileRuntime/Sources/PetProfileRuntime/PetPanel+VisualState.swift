// PetPanel+VisualState.swift
// PetPanel 的 VisualState 扩展（不改 frozen 的 PetPanel.swift）
//
// 提供：
//   - func setVisualState(_ state: VisualState)
//     内部调 switchVisualState（frozen API），成功时投递 .petVisualStateChanged notification
//   - var visualState: VisualState  — 从 currentState: String 转过来
//
// 关键路径：
//   - Router.handle(event) → panel.setVisualState(state) → 调 switchVisualState
//     → 改 imageView.image + 写 currentState: String → 投递 notification
//   - 单测可以观察 notification 或读 currentState: String 验证

import AppKit
import Foundation

extension PetPanel {

    /// 当前 VisualState（从 frozen 的 currentState: String 转）。
    /// 解析失败返回 nil（旧 profile 可能用了 schema 外的 state 名）。
    public var visualState: VisualState? {
        return VisualState.parse(currentState)
    }

    /// 切到指定 VisualState。**只更新 state 字段 + 发通知，不实现 NSPanel 实际动画**。
    /// - 内部走 switchVisualState(_:String)（frozen API），返回 true 时投递 notification
    /// - 返回值：true = 切成功，false = asset 缺失（保持原 state）
    @discardableResult
    public func setVisualState(_ state: VisualState) -> Bool {
        let ok = self.switchVisualState(state.rawValue)
        if ok {
            NotificationCenter.default.post(
                name: .petVisualStateChanged,
                object: self,
                userInfo: ["state": state]
            )
        }
        return ok
    }
}

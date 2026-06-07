// ActionRouter.swift
// PetActionRouter — 接收用户输入事件 + 焦点事件，调度 multi-channel response
//
// 责任：
//   - 把 PetEvent 解析成 (state, reaction?, catchphrase?)
//   - 维护 currentState: VisualState（idle / focus / happy / tired / celebrate）
//   - 调 ChannelDispatcher 按 expression → action → audio 顺序打 sink
//   - 调 panel.setVisualState 更新 panel 显示
//   - audio cooldown：同一 catchphrase 在 cooldownSeconds 内不重复播
//
// 设计决策：
//   - **PetEvent 跟 schema.Trigger 的映射**：
//     schema 同时支持新式（drag_start / drag_end）和旧式（drag）；
//     PetEvent 有 dragStart / dragEnd，handle() 内做 candidateTriggers 查询
//     [dragStart → .dragStart, .drag] 优先精确匹配，回退到父 trigger。
//     兼容 v0.1.0 profile（Mitu/Zorp 旧 fixture 用了 "drag"）。
//   - **derived state 表**：
//     focus_start → .focus, focus_end → .idle, task_done → .celebrate
//     其他 click 类事件 → 先看 catchphrase.expression（schema 里的字段），
//     没设就 .happy（积极反应默认）
//   - **不接真 audio / 真 spring**：
//     audio cooldown 只跳过"playAudio 调用"，不引入 AVFoundation
//     springParams 在 ActionReaction 里传递，渲染由后续 plan 接管
//   - **时间可注入**：
//     timeProvider 默认 Date().timeIntervalSince1970，
//     测试用确定性时间控制 cooldown 行为
//
// 不做：
//   - focus / task 业务逻辑（依赖外部系统，pet-runtime P2-D 处理）
//   - AI 生成 catchphrase（pet-brain 范围）
//   - NSPanel 实际动画（PetPanel+VisualState 已经 hook 给后续 plan）
//   - 长按 / 双击 / 摇窗的手势识别（路由层只接受已识别好的 PetEvent）

import AppKit
import Foundation
import PetProfile

// MARK: - PetEvent

/// runtime 抽象的用户 / 系统事件。和 schema.Trigger 1:1 对齐 + 加上 drag 的细分。
///
/// 注意：dragStart / dragEnd 在 schema 里是 .dragStart / .dragEnd，
/// 但旧 profile 用 .drag（单一 trigger）。Router 在查 reaction/catchphrase
/// 时两个都查，命中即用。
public enum PetEvent: Sendable, Equatable, Hashable {
    // 用户输入
    case click
    case doubleClick
    case longPress
    case dragStart
    case dragEnd
    case hoverEnter
    case hoverLeave
    case shakeWindow
    // 焦点 / 任务事件（来自 P2-D focus / task companion）
    case focusStart
    case focusEnd
    case taskDone

    /// 事件对应的 schema.Trigger 数组（drag 类的回退匹配）。
    /// PetActionRouter 内部用：先尝试第一个，命中即用；否则试第二个。
    public var candidateTriggers: [Trigger] {
        switch self {
        case .click:       return [.click]
        case .doubleClick: return [.doubleClick]
        case .longPress:   return [.longPress]
        case .dragStart:   return [.dragStart, .drag]
        case .dragEnd:     return [.dragEnd, .drag]
        case .hoverEnter:  return [.hoverEnter]
        case .hoverLeave:  return [.hoverLeave]
        case .shakeWindow: return [.shakeWindow]
        case .focusStart:  return [.focusStart]
        case .focusEnd:    return [.focusEnd]
        case .taskDone:    return [.taskDone]
        }
    }
}

// MARK: - PetActionRouter

public final class PetActionRouter {

    /// 当前 VisualState。初始 .idle。
    /// 由 handle(event) 维护：focus_start → .focus，task_done → .celebrate 等。
    public private(set) var currentState: VisualState = .idle

    private let profile: LoadedPetProfile
    private let panel: PetPanel
    private let dispatcher: ChannelDispatcher
    private var lastAudioTimes: [String: TimeInterval] = [:]
    private let timeProvider: () -> TimeInterval

    /// 构造一个 router。
    /// - Parameters:
    ///   - profile: 加载后的 profile
    ///   - panel: 透明 NSPanel（router 调 panel.setVisualState 同步 state）
    ///   - sink: 可选；nil 时构造默认的 PanelChannelSink
    ///   - timeProvider: 可选；用于测试时间（cooldown 判定）
    public init(
        profile: LoadedPetProfile,
        panel: PetPanel,
        sink: ChannelSink? = nil,
        timeProvider: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) {
        self.profile = profile
        self.panel = panel
        self.timeProvider = timeProvider
        let actualSink: ChannelSink = sink ?? PanelChannelSink(panel: panel)
        self.dispatcher = ChannelDispatcher(sink: actualSink)
    }

    // MARK: - public API

    /// 处理一个 PetEvent。
    ///
    /// 流程：
    ///   1. 解析 derived state（focus_start → .focus 等）
    ///   2. 写 currentState + 调 panel.setVisualState
    ///   3. 查 action.reactions（按 candidateTriggers）→ ActionReaction?
    ///   4. 查 audio.catchphrases（按 candidateTriggers）→ AudioCatchphrase?
    ///   5. 调 dispatcher.dispatch(expression, action, audio)
    ///      audio 受 cooldown 控制：cooldown 内的 catchphrase 传 nil
    public func handle(event: PetEvent) {
        let nextState = derivedState(for: event)
        currentState = nextState
        // 同步 panel（asset 缺失时 silently 保持原 state，不抛错）
        panel.setVisualState(nextState)

        let reaction = findReaction(for: event)
        let catchphrase = findCatchphrase(for: event)
        let playableCatchphrase = gateOnCooldown(catchphrase)

        dispatcher.dispatch(
            expression: nextState,
            action: reaction,
            audio: playableCatchphrase
        )
    }

    /// 给测试用：手动覆盖 currentState（不调 panel，不投递 notification）。
    /// 主要用于 setUp 阶段的已知状态初始化。
    public func _setCurrentStateForTesting(_ state: VisualState) {
        self.currentState = state
    }

    // MARK: - derived state

    /// 事件 → 期望 VisualState。
    /// 显式映射（focus/task）；click 类事件查 catchphrase.expression；没有就 .happy。
    func derivedState(for event: PetEvent) -> VisualState {
        switch event {
        case .focusStart:
            return .focus
        case .focusEnd:
            return .idle
        case .taskDone:
            return .celebrate
        case .click, .doubleClick, .longPress,
             .dragStart, .dragEnd, .hoverEnter, .hoverLeave, .shakeWindow:
            // 1. 优先 catchphrase.expression（schema 里 audio.catchphrases[i].expression）
            if let cp = findCatchphrase(for: event),
               let expr = cp.expression,
               let parsed = VisualState.parse(expr) {
                return parsed
            }
            // 2. 默认 happy（"被戳一下很开心"的宠物直觉）
            return .happy
        }
    }

    // MARK: - reaction / catchphrase lookup

    func findReaction(for event: PetEvent) -> ActionReaction? {
        let candidates = event.candidateTriggers
        // primary trigger = 事件的 primary 类型（dragStart 命中 .drag reaction 时记录 dragStart）
        let primaryTrigger = candidates.first
        for r in profile.manifest.action.reactions {
            if candidates.contains(r.trigger) {
                let trigger = primaryTrigger ?? r.trigger
                return ActionReaction.from(r, withTrigger: trigger)
            }
        }
        return nil
    }

    func findCatchphrase(for event: PetEvent) -> AudioCatchphrase? {
        let candidates = event.candidateTriggers
        for cp in profile.manifest.audio.catchphrases {
            if candidates.contains(cp.trigger) {
                return AudioCatchphrase.from(cp)
            }
        }
        return nil
    }

    // MARK: - audio cooldown

    /// 按 cooldownSeconds 决定是否播放。
    /// 同一 text 在 cooldown 内再次触发 → 返回 nil（dispatcher 仍会调 sink.playAudio(nil)）
    private func gateOnCooldown(_ catchphrase: AudioCatchphrase?) -> AudioCatchphrase? {
        guard let cp = catchphrase else { return nil }
        let now = timeProvider()
        if let last = lastAudioTimes[cp.text] {
            if now - last < cp.cooldownSeconds {
                return nil
            }
        }
        lastAudioTimes[cp.text] = now
        return cp
    }
}

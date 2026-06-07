// ChannelDispatcher.swift
// 多通道调度 — ChannelSink 协议 + ActionReaction / AudioCatchphrase 包装
//  + PanelChannelSink 默认实现
//
// 责任：
//   - 定义 ChannelSink 协议（expression / action / audio 三个通道）
//   - 把 PetProfileKit 的 Reaction / Catchphrase 包装成 runtime 层的 ActionReaction / AudioCatchphrase
//   - 提供 ChannelDispatcher：保证 expression → action → audio 的调用顺序
//   - 提供 PanelChannelSink：把 3 通道打到 PetPanel 上（expression 走 setVisualState，
//     action / audio 走 NotificationCenter 投递 + 留 hook 给后续 plan 接真渲染）
//
// 设计决策：
//   - ChannelSink 是协议（不是 class）+ AnyObject（用 weak 引用避免循环）
//   - ChannelKind 用 Comparable enum 表达通道优先级（expression < action < audio）
//   - ActionReaction / AudioCatchphrase 是 runtime 层 struct，跟 PetProfileKit 解耦：
//     升级 schema（v1.1 / v2）时只改 .from(_:) 即可
//   - springParams 字段从 reaction.name 查表（"jelly-bounce" → jellyBounceParams）
//     不在 schema 里硬塞 spring 数据（Mitu/Zorp 以后只要加 namedParams 表项）
//   - PanelChannelSink 不接真 audio（接了 = 引入 AVFoundation；那是后续 plan）；
//     通过 NotificationCenter 投递 .petActionPlayed / .petAudioPlayed
//     让 main entry / status bar 自行订阅
//
// 不做：
//   - 真 audio 播放（AVAudioPlayer / TTS）
//   - 真 spring 渲染（CABasicAnimation / CASpringAnimation）
//   - audio cooldown 逻辑（那是 PetActionRouter 的事，不是 dispatcher 的事）

import AppKit
import Foundation
import PetProfile

// MARK: - ActionReaction

/// runtime 层的 action reaction。decoupled from PetProfileKit.Reaction。
/// 包含 spring 动画参数（如果是 spring-animation format），让 sink 一次拿到所有渲染信息。
public struct ActionReaction: Equatable, Sendable, Hashable {
    public let name: String
    public let trigger: Trigger
    public let durationMs: Int
    public let assetFormat: AssetFormat?
    public let interruptsIdle: Bool
    public let cooldownMs: Int
    public let springParams: SpringParams?

    public init(
        name: String,
        trigger: Trigger,
        durationMs: Int,
        assetFormat: AssetFormat?,
        interruptsIdle: Bool,
        cooldownMs: Int,
        springParams: SpringParams?
    ) {
        self.name = name
        self.trigger = trigger
        self.durationMs = durationMs
        self.assetFormat = assetFormat
        self.interruptsIdle = interruptsIdle
        self.cooldownMs = cooldownMs
        self.springParams = springParams
    }

    /// 从 PetProfileKit.Reaction 包装。
    /// - Parameter withTrigger: 用事件触发的 trigger 覆盖 reaction.trigger
    ///   （dragStart 命中 .drag reaction 时，runtime 端记录 dragStart，更精准）
    public static func from(_ reaction: Reaction, withTrigger trigger: Trigger) -> ActionReaction {
        let spring: SpringParams?
        if reaction.assetFormat == .springAnimation {
            spring = SpringAnimation.namedParams(reaction.name) ?? SpringAnimation.defaultSpringParams()
        } else {
            spring = nil
        }
        return ActionReaction(
            name: reaction.name,
            trigger: trigger,
            durationMs: reaction.durationMs,
            assetFormat: reaction.assetFormat,
            interruptsIdle: reaction.interruptsIdle,
            cooldownMs: reaction.cooldownMs,
            springParams: spring
        )
    }

    public var hasSpring: Bool { springParams != nil }
}

// MARK: - AudioCatchphrase

/// runtime 层的 audio catchphrase。decoupled from PetProfileKit.Catchphrase。
public struct AudioCatchphrase: Equatable, Sendable, Hashable {
    public let text: String
    public let trigger: Trigger
    public let cooldownSeconds: Double
    public let expression: String?  // raw 字符串，caller 决定要不要 parse 成 VisualState

    public init(text: String, trigger: Trigger, cooldownSeconds: Double, expression: String?) {
        self.text = text
        self.trigger = trigger
        self.cooldownSeconds = cooldownSeconds
        self.expression = expression
    }

    public static func from(_ catchphrase: Catchphrase) -> AudioCatchphrase {
        return AudioCatchphrase(
            text: catchphrase.text,
            trigger: catchphrase.trigger,
            cooldownSeconds: catchphrase.cooldownSeconds ?? 30.0,
            expression: catchphrase.expression
        )
    }
}

// MARK: - ChannelKind

/// 3 通道优先级。Comparable 让 dispatch 算法可以排序。
/// 顺序固定：expression (cheapest) → action → audio (heaviest, skippable)
public enum ChannelKind: Int, Sendable, Comparable, CaseIterable {
    case expression = 0
    case action = 1
    case audio = 2

    public static func < (lhs: ChannelKind, rhs: ChannelKind) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - ChannelSink

public protocol ChannelSink: AnyObject {
    /// 切 expression（最便宜，先切）。VisualState 表达"宠物现在长什么样"。
    func playExpression(_ state: VisualState)
    /// 播 action 动画（mp4-alpha / apng / spring-animation）。
    /// reaction.springParams != nil 时是 spring 动画（pure-function scale 序列）。
    func playAction(_ reaction: ActionReaction)
    /// 播 audio 口头禅（最重，可能被省 / 失败降级）。
    /// nil 表示 sink 收到"无 catchphrase"信号，sink 可以选择播一个静音占位
    /// 或完全 skip（默认实现 skip）。
    func playAudio(_ catchphrase: AudioCatchphrase?)
}

// MARK: - ChannelDispatcher

/// 多通道调度器。**核心 invariant：expression 必先于 action 必先于 audio**。
///
/// 公共 API：
///   - init(sink:ordering:) — ordering 默认 [.expression, .action, .audio]（按 rawValue 升序）
///   - dispatch(expression:action:audio:) — 一次性投递三通道；nil 通道跳过
///
/// 不做：
///   - 状态机（那是 PetActionRouter）
///   - audio cooldown（Router 内自己管 lastAudioTimes）
public final class ChannelDispatcher {
    public let ordering: [ChannelKind]
    private let sink: ChannelSink

    public init(sink: ChannelSink, ordering: [ChannelKind]? = nil) {
        if let o = ordering {
            // 防御：去重（保持顺序），让 caller 决定 priority
            var seen: Set<ChannelKind> = []
            self.ordering = o.filter { seen.insert($0).inserted }
        } else {
            self.ordering = ChannelKind.allCases  // [.expression, .action, .audio]
        }
        self.sink = sink
    }

    /// 按 ordering 顺序投递三通道。
    /// - Parameter expression: 必传（expression 是最便宜的，总能切）
    /// - Parameter action: 可选；nil = 此事件无 action reaction（如 focus_start）
    /// - Parameter audio: 可选；nil = 此事件无 audio catchphrase
    public func dispatch(
        expression: VisualState,
        action: ActionReaction?,
        audio: AudioCatchphrase?
    ) {
        for kind in ordering {
            switch kind {
            case .expression:
                sink.playExpression(expression)
            case .action:
                if let a = action {
                    sink.playAction(a)
                }
            case .audio:
                // audio 即使传 nil 也调 sink（让 sink 知道"现在没 catchphrase"）
                // 默认 PanelChannelSink / MockChannelSink 在 nil 时 skip
                sink.playAudio(audio)
            }
        }
    }
}

// MARK: - PanelChannelSink

/// 默认 ChannelSink：把 3 通道打到 PetPanel + 投递 notification。
///
///   - playExpression: 调 panel.setVisualState（直接走 VisualState 路径）
///   - playAction: 投递 .petActionPlayed notification（含 reaction 全部字段）
///   - playAudio: 投递 .petAudioPlayed notification（含 catchphrase 全部字段）
///
/// 真渲染留给后续 plan；这里只做"事件总线"，不接 CASpringAnimation / AVAudioPlayer。
public final class PanelChannelSink: ChannelSink {
    private let panel: PetPanel

    public init(panel: PetPanel) {
        self.panel = panel
    }

    public func playExpression(_ state: VisualState) {
        // setVisualState 是 PetPanel+VisualState.swift 里的 extension
        panel.setVisualState(state)
    }

    public func playAction(_ reaction: ActionReaction) {
        NotificationCenter.default.post(
            name: .petActionPlayed,
            object: panel,
            userInfo: ["reaction": reaction]
        )
    }

    public func playAudio(_ catchphrase: AudioCatchphrase?) {
        // nil 也投递，让 observer 知道"这一拍没口头禅"
        NotificationCenter.default.post(
            name: .petAudioPlayed,
            object: panel,
            userInfo: ["catchphrase": catchphrase as Any]
        )
    }
}

public extension Notification.Name {
    /// 投递于 ChannelSink.playAction(reaction)。
    /// userInfo: ["reaction": ActionReaction]
    static let petActionPlayed = Notification.Name("PetProfileRuntime.petActionPlayed")
    /// 投递于 ChannelSink.playAudio(catchphrase: nil 也投递)。
    /// userInfo: ["catchphrase": AudioCatchphrase?]
    static let petAudioPlayed = Notification.Name("PetProfileRuntime.petAudioPlayed")
}

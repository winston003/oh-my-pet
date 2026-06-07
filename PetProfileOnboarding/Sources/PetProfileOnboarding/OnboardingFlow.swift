// OnboardingFlow.swift
// OnboardingFlow — ObservableObject 状态机
//
// 设计决策：
//   - ObservableObject + @Published state（SwiftUI 友好）
//   - 所有 mutating 操作都先改 in-memory state，再调 state.save() 落盘
//     失败时回滚 in-memory（让 UI 立刻知道错）
//   - state machine 行为：
//     - choose(path:)    → 写 chosenPath + 计算 first stage（welcome → 下一 stage）
//     - saveByok(...)    → 写 BYOK + 校验（path 是 C/D 时拒绝）
//     - saveProfile(at:) → 写 petProfilePath
//     - saveVoice(...)   → 写 voice style + 校验 consent（cloned=true 但 consent 缺失或无效 → 拒绝）
//     - markLaunched()   → 写 launchTime
//     - next()           → 推进到当前 path 对应的下一 stage
//     - back()           → 回退到当前 path 对应的上一 stage
//     - reset()          → 删盘 + 重置 state
//   - 跳 stage 算法由 OnboardingPath.expectedStageSequence 决定（C/D 跳过 1.5/2/3）
//   - save 失败抛 OnboardingError.persistenceWriteFailed；UI 决定是否提示
//
// 不做：
//   - 不接真 LLM / 不接真 BYOK（saveByok 只存字符串 + 引用 key）
//   - 不调真 profile loader（saveProfile 只存 URL，不解析）
//   - 不直接跑 NSApp.run()（main entry 负责）
//

import Foundation
import Combine
import PetProfile
import PetProfileRuntime
import PetProfileBrain

public final class OnboardingFlow: ObservableObject {

    @Published public private(set) var state: OnboardingState

    /// 持久化目标 URL（nil = 默认 `~/Library/Application Support/oh-my-pet/onboarding-state.json`）。
    /// 测试可以注入临时目录 URL，避免污染真 ~/Library。
    public let storeURL: URL?

    public init(initialState: OnboardingState = OnboardingState(), storeURL: URL? = nil) {
        self.state = initialState
        self.storeURL = storeURL
    }

    /// 写盘：storeURL ?? defaultURL
    private func persist(_ snapshot: OnboardingState) throws {
        var copy = snapshot
        if let url = storeURL {
            try copy.save(to: url)
        } else {
            try copy.save()
        }
    }

    /// 删盘：storeURL ?? defaultURL
    private func wipe() throws {
        if let url = storeURL {
            try OnboardingState.delete(at: url)
        } else {
            try OnboardingState.delete()
        }
    }

    // MARK: - 状态机主入口

    /// 选 onboarding 起始路径（Stage 1 完成时调）
    /// 自动从 .welcome 推进到 path 对应的下一 stage
    public func choose(path: OnboardingPath) throws {
        guard state.currentStage == .welcome else {
            throw OnboardingError.invalidStageTransition(
                from: state.currentStage,
                to: nextStageAfterWelcome(for: path)
            )
        }
        var newState = state
        newState.chosenPath = path
        newState.currentStage = nextStageAfterWelcome(for: path)
        try persist(newState)
        state = newState
    }

    /// 写 BYOK 配置（Stage 1.5 完成时调）
    /// - 路径是 C/D → 拒绝（不需要 BYOK）
    public func saveByok(provider: String, keychainRef: String?) throws {
        guard let path = state.chosenPath else {
            throw OnboardingError.byokNotRequiredForPath
        }
        guard path.needsByok else {
            throw OnboardingError.byokNotRequiredForPath
        }
        guard state.currentStage == .byokSetup else {
            throw OnboardingError.invalidStageTransition(from: state.currentStage, to: .byokSetup)
        }
        var newState = state
        newState.byokProvider = provider
        newState.byokKeychainRef = keychainRef
        try persist(newState)
        state = newState
    }

    /// 写 pet profile 路径（Stage 2 / D 路径 / C 路径 完成时调）
    public func saveProfile(at url: URL) throws {
        var newState = state
        newState.petProfilePath = url
        try persist(newState)
        state = newState
    }

    /// 写 pet 声音（Stage 3 完成时调）
    /// - cloned=true 但 voiceCloneConsent 缺失或无效 → 抛 .consentRequired（红线）
    public func saveVoice(style: String?, cloned: Bool) throws {
        var newState = state
        if cloned {
            // 红线：clone 必须有 valid consent
            guard let consent = newState.voiceCloneConsent, consent.isValid else {
                throw OnboardingError.consentRequired
            }
            newState.voiceCloned = true
        } else {
            newState.voiceCloned = false
            // 不 clone → 清掉旧 consent（避免 stale 状态）
            newState.voiceCloneConsent = nil
        }
        newState.voiceStyle = style
        try persist(newState)
        state = newState
    }

    /// Stage 3 用户勾选 consent 时调（让 flow 持有 consent；后续 saveVoice(cloned:true) 才不报红线）
    public func recordVoiceCloneConsent(_ consent: VoiceCloneConsent) throws {
        var newState = state
        newState.voiceCloneConsent = consent
        try persist(newState)
        state = newState
    }

    /// 标记首次 launch 完成（Stage 4 完成时调）
    public func markLaunched() throws {
        var newState = state
        newState.launchTime = Date()
        newState.currentStage = .completed
        try persist(newState)
        state = newState
    }

    /// 推进到下一 stage（按 chosenPath 决定下一 stage）
    public func next() throws {
        guard state.currentStage != .completed else {
            throw OnboardingError.alreadyCompleted
        }
        let nextStage = nextStageAfterCurrent()
        var newState = state
        newState.currentStage = nextStage
        try persist(newState)
        state = newState
    }

    /// 回退到上一 stage
    public func back() throws {
        guard let prev = previousStageBeforeCurrent() else {
            throw OnboardingError.cannotGoBack
        }
        var newState = state
        newState.currentStage = prev
        try persist(newState)
        state = newState
    }

    /// 重置（删盘 + fresh state）—— 给「重新开始 onboarding」用
    /// 失败恢复：corrupted state → reset() → 从 Stage 1 开始
    public func reset() throws {
        try wipe()
        state = OnboardingState()
    }

    // MARK: - 状态机计算（pure）

    /// welcome → path 对应的下一 stage
    public func nextStageAfterWelcome(for path: OnboardingPath) -> OnboardingStage {
        let seq = path.expectedStageSequence
        // seq[0] == .welcome; 下一 stage = seq[1]
        if seq.count >= 2 { return seq[1] }
        return .completed
    }

    /// 当前 stage → 下一 stage（按 path 决定；C/D 跳过 1.5/2/3）
    public func nextStageAfterCurrent() -> OnboardingStage {
        guard let path = state.chosenPath else {
            // 没选 path → 强制回 .welcome
            return .welcome
        }
        let seq = path.expectedStageSequence
        guard let idx = seq.firstIndex(of: state.currentStage) else {
            // 不在 seq 里（C/D 走特殊路径，比如 import 失败回退）
            return .welcome
        }
        let nextIdx = idx + 1
        if nextIdx < seq.count {
            return seq[nextIdx]
        }
        return .completed
    }

    /// 当前 stage → 上一 stage
    public func previousStageBeforeCurrent() -> OnboardingStage? {
        guard let path = state.chosenPath else {
            // 没选 path → 已是 .welcome，没有"前一"
            return nil
        }
        let seq = path.expectedStageSequence
        guard let idx = seq.firstIndex(of: state.currentStage) else {
            return nil
        }
        let prevIdx = idx - 1
        if prevIdx >= 0 {
            return seq[prevIdx]
        }
        return nil
    }

    // MARK: - 阶段间派生信息（给 UI 用）

    /// 跳过 Stage 1.5？（path 是 C/D 时为 true）
    public var skipsByok: Bool {
        guard let p = state.chosenPath else { return true }
        return !p.needsByok
    }

    /// 跳过 Stage 2/3？（path 是 C/D 时为 true）
    public var skipsVisualAndVoice: Bool {
        guard let p = state.chosenPath else { return true }
        return !p.needsVisualAndVoice
    }

    /// 进度（0.0 - 1.0）—— 给 SwiftUI ProgressView 用
    public var progress: Double {
        guard let path = state.chosenPath else { return 0.0 }
        let seq = path.expectedStageSequence
        guard let idx = seq.firstIndex(of: state.currentStage) else { return 0.0 }
        return Double(idx) / Double(max(seq.count - 1, 1))
    }
}

// OnboardingTypes.swift
// Onboarding 的核心类型：Stage / Path / Error / Consent
//
// 设计决策：
//   - Stage 枚举用 string-backed Codable，持久化稳定（不依赖 Swift 编译器顺序）
//   - Path 4 个：generate / upload / import / sample —— 跟 onboarding-flow.md §2 Stage 1 对齐
//   - Error 用 OnboardingError，明确区分持久化失败 / stage 越界 / consent 缺失 / 路径冲突
//   - VoiceCloneConsent 单独 struct，**必须** userConfirmsOwnership=true 才允许 clone
//     （红线 — AGENTS.md "Voice And Consent" + onboarding-flow.md §2 Stage 3）
//
// 持久化字段名（snake_case）：跟 PetProfileKit.ProfileIO 对齐（sortable + grep 友好）
//

import Foundation

// MARK: - OnboardingStage

/// 5 阶段 onboarding 状态机的节点
/// - welcome:     Stage 1（4 路径选择）
/// - byokSetup:   Stage 1.5（BYOK 配置，仅 A/B 触发）
/// - visualCreate: Stage 2（pet 视觉）
/// - voiceCreate:  Stage 3（pet 声音）
/// - launchPet:    Stage 4（首次 launch 桌面 pet）
/// - completed:    终态（不可再走 forward/back）
public enum OnboardingStage: String, Codable, Equatable, Sendable, CaseIterable {
    case welcome
    case byokSetup
    case visualCreate
    case voiceCreate
    case launchPet
    case completed

    /// 人类可读名（给 UI label 用）
    public var displayName: String {
        switch self {
        case .welcome:      return "Stage 1 — 欢迎"
        case .byokSetup:    return "Stage 1.5 — BYOK"
        case .visualCreate: return "Stage 2 — 视觉"
        case .voiceCreate:  return "Stage 3 — 声音"
        case .launchPet:    return "Stage 4 — 首次 launch"
        case .completed:    return "完成"
        }
    }
}

// MARK: - OnboardingPath

/// 4 个 onboarding 起始路径
/// 跟 onboarding-flow.md §2 Stage 1 4 路径选择对齐
public enum OnboardingPath: String, Codable, Equatable, Sendable, CaseIterable {
    /// A: AI 文字 → image 生成新 pet（需要 AI provider）
    case generate
    /// B: 上传参考图 → image-to-image 生成（需要 AI provider）
    case upload
    /// C: 从已有 .omppet / .zip 文件导入（不需要 AI provider）
    case importPath = "import"
    /// D: 用内置 sample（Pako / Mitu / Zorp 之一）
    case sample

    /// 是否需要走 Stage 1.5 BYOK 配置
    /// A/B → true；C/D → false
    public var needsByok: Bool {
        switch self {
        case .generate, .upload: return true
        case .importPath, .sample: return false
        }
    }

    /// 是否需要走 Stage 2 / Stage 3（视觉 / 声音创建）
    /// C/D → 跳过（直接用现成 profile）
    /// A/B → 必走
    public var needsVisualAndVoice: Bool {
        switch self {
        case .generate, .upload: return true
        case .importPath, .sample: return false
        }
    }

    /// 路径 + 完成 stage 列表 —— 给 UI 展示「还要走几步」用
    public var expectedStageSequence: [OnboardingStage] {
        var seq: [OnboardingStage] = [.welcome]
        if needsByok { seq.append(.byokSetup) }
        if needsVisualAndVoice {
            seq.append(.visualCreate)
            seq.append(.voiceCreate)
        }
        seq.append(.launchPet)
        seq.append(.completed)
        return seq
    }
}

// MARK: - VoiceCloneConsent

/// Stage 3 voice clone 的显式 consent 记录
/// 红线：userConfirmsOwnership == true 才允许走 clone；否则 OnboardingError.consentRequired
public struct VoiceCloneConsent: Codable, Equatable, Sendable {
    /// 用户上传的样本文件名（仅记录名，不存音频 — 音频属用户本地，不归 onboarding state 管）
    public let sampleFilename: String
    /// **必填 true** — 用户明确声明"我拥有这个样本，或有授权使用它"
    public let userConfirmsOwnership: Bool
    /// 用户勾选 consent 的时刻（ISO8601）
    public let consentTimestamp: Date

    public init(sampleFilename: String, userConfirmsOwnership: Bool, consentTimestamp: Date = Date()) {
        self.sampleFilename = sampleFilename
        self.userConfirmsOwnership = userConfirmsOwnership
        self.consentTimestamp = consentTimestamp
    }

    /// 红线校验：consent 是否有效
    public var isValid: Bool {
        // 必须显式勾选；filename 至少 1 字符（防误提交空文件）
        return userConfirmsOwnership && !sampleFilename.isEmpty
    }
}

// MARK: - OnboardingError

public enum OnboardingError: Error, CustomStringConvertible, Equatable {
    /// 持久化写盘失败（IO / 编码 / 权限）
    case persistenceWriteFailed(reason: String)
    /// 持久化读盘失败（损坏 / 解码失败 / 不存在）
    /// 注：load() 区分 .corrupted vs .notFound —— 测试需要
    case persistenceReadFailed(reason: String)
    case stateFileCorrupted(reason: String)
    case stateFileNotFound
    /// 用户在 voice clone 路径没勾 consent 强提交
    case consentRequired
    /// 在 .completed 之后又调 next()
    case alreadyCompleted
    /// 在 .welcome 之前调 back()（没有"前一 stage"）
    case cannotGoBack
    /// 跳到 .byokSetup 时 path 是 C/D（不需要 BYOK）
    case byokNotRequiredForPath
    /// 跳到 .visualCreate / .voiceCreate 时 path 是 C/D
    case visualAndVoiceNotRequiredForPath
    /// 选 path 后跳 stage 算错（state machine 内部一致性出错）
    case invalidStageTransition(from: OnboardingStage, to: OnboardingStage)

    public var description: String {
        switch self {
        case .persistenceWriteFailed(let r):
            return "OnboardingState save failed: \(r)"
        case .persistenceReadFailed(let r):
            return "OnboardingState load failed: \(r)"
        case .stateFileCorrupted(let r):
            return "OnboardingState file corrupted: \(r)"
        case .stateFileNotFound:
            return "OnboardingState file not found"
        case .consentRequired:
            return "voice clone requires explicit consent (userConfirmsOwnership=true)"
        case .alreadyCompleted:
            return "onboarding already completed"
        case .cannotGoBack:
            return "cannot go back from this stage"
        case .byokNotRequiredForPath:
            return "BYOK not required for chosen path (C/D skip Stage 1.5)"
        case .visualAndVoiceNotRequiredForPath:
            return "visual/voice creation not required for chosen path (C/D skip Stage 2/3)"
        case .invalidStageTransition(let f, let t):
            return "invalid stage transition: \(f) -> \(t)"
        }
    }
}

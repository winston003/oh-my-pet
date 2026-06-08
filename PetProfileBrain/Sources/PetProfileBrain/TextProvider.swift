// TextProvider.swift
// TextProvider — 文本生成 provider 协议 + 协议数据类型
//
// 协议层对应 spec §3.1 Provider 三元组中的 TextProvider：
//   - 5 个 action（translate / explain / summarize / rewrite / ask）
//   - 输入 selectedText + 可选 app context + 可选 pet 人设
//   - 输出原始 completion text + metadata
//   - 实际实现可以是 StubTextProvider（默认，本地 echo）
//   - 也可以是 AI provider（OpenAI / Claude）—— 这些目前是 stub，留协议钩子，
//     UI 在用户配了 provider key 之后才显示
//
// 设计要点（与 ImageProvider 同形 API，方便 P2-L-2 / P2-L-3 复用同一注册中心风格）：
//   - TextProvider: Sendable 协议
//   - TextCompletionRequest 5 个 field（action / selectedText / appContext / petID / model）
//   - TextCompletionResult 5 个 field（text / providerID / modelUsed / tokensUsed / latencyMS）
//   - SelectionActionKind 5 个 case，对应 spec §3.1 的 5 个 action
//   - AppContextSnapshot 用 struct + Equatable（用于未来缓存去重 / 测试断言）
//   - 所有类型 Sendable + Codable，便于跨 actor / 跨模块传
//
// **AppContextSnapshot 为什么放在 TextProvider 这一层**（关键设计决策）：
//   - app context 是 "AI 调用请求的输入"，不是 "Selection 触发层的事"。
//   - 触发层（P2-L-2）负责捕获并塞到 request.appContext；
//   - provider 层（这里）只负责消费它，不需要 import AppKit 也能定义数据类型。
//   - 放在更上游（如 Runtime / Studio）会强制 provider 反向依赖 UI 层，
//     违反 spec §4.2 "依赖方向：Core 层不 import UI 层"。
//
// 不做：
//   - 不接真 OpenAI / Claude / SD / Replicate API（属 stub 阶段）
//   - 不实现 streaming / partial progress（TextCompletionRequest → Result 是单次）
//   - 不引入第三方 SDK（spec §3.1 禁止 import 具体 provider；PetProfileLLM 也不应 import
//     "OpenAI" / "Anthropic" / "FoundationModels" 这种具体 SDK 名字）
//

import Foundation
import PetProfile

// MARK: - PetProfileSummary

/// Pet 人设的"prompt-friendly" 摘要 — TextCompletionRequest.petProfile 用这个，
/// **不**直接拖 LoadedPetProfile / PetProfileV1 进网络协议。
///
/// 设计理由（P2-L-3 决策）：
///   - TextCompletionRequest 是跨 layer 的协议数据契约（SelectionCoordinator → provider）。
///     LoadedPetProfile 携带 URL（visualAssetURLs 等），不适合序列化 / 跨进程 / 测试。
///   - PetProfileV1 是 Kit 层 schema，字段多；prompt 编排只需要 4 段信息。
///   - PetProfileSummary = (name, species, humorStyle, storyTone) — profile-driven，无 hardcode。
///   - PetProfileLLM（OpenAITextProvider）通过这个 DTO 拿人设，**不** import PetProfileRuntime
///     （保持 spec §4.2 "Core 层不 import UI" 反向依赖红线）。
///
/// 字段映射（**不** hardcode 任何 pet 字段）：
///   - name = manifest.name
///   - species = manifest.persona.backstoryTags?.first ?? manifest.persona.loreShort
///   - humorStyle = manifest.humor.humorStyle.rawValue（"self-deprecating" / "gentle" / "sarcastic" / ...）
///   - storyTone = manifest.persona.relationshipWithUser ?? "neutral"（spec P7 story 通道）
public struct PetProfileSummary: Sendable, Codable, Equatable, Hashable {
    public let name: String
    public let species: String
    public let humorStyle: String
    public let storyTone: String

    public init(
        name: String,
        species: String,
        humorStyle: String,
        storyTone: String
    ) {
        self.name = name
        self.species = species
        self.humorStyle = humorStyle
        self.storyTone = storyTone
    }

    /// 从 v1 manifest 派生 summary。集中所有"pet 字段 → prompt 字段"的映射逻辑，
    /// 调用方（SelectionCoordinator / 测试）不重复实现。
    public static func from(manifest: PetProfileV1) -> PetProfileSummary {
        let species: String
        if let first = manifest.persona.backstoryTags?.first, !first.isEmpty {
            species = first
        } else if !manifest.persona.loreShort.isEmpty {
            species = manifest.persona.loreShort
        } else {
            species = "companion"
        }

        let tone: String
        if let rel = manifest.persona.relationshipWithUser, !rel.isEmpty {
            tone = rel
        } else {
            tone = "neutral"
        }

        return PetProfileSummary(
            name: manifest.name,
            species: species,
            humorStyle: manifest.humor.humorStyle.rawValue,
            storyTone: tone
        )
    }
}

// MARK: - TextProvider protocol

/// 文本生成 provider 协议。注册到 TextProviderRegistry，
/// UI 通过 registry 列出所有可用 provider，调用方不直接 import 具体 SDK。
public protocol TextProvider: Sendable {
    /// Provider 唯一标识（如 "stub" / "openai-gpt" / "anthropic-claude"）
    var id: String { get }

    /// UI 显示名（如 "Stub" / "OpenAI GPT"）
    var displayName: String { get }

    /// 是否需要 API key（Keychain 凭据）
    ///   - true: UI 需先检测 Keychain 是否有 key，没有就 disable 该 provider
    ///   - false: 无凭据依赖（如 stub）
    var requiresAPIKey: Bool { get }

    /// 支持的 action 集合（决定 UI 上哪几个 action 按钮 enabled）。
    /// Stub 全 5 个都支持；真 provider 可能 subset。
    var supportedActions: Set<SelectionActionKind> { get }

    /// 给定请求，返回 completion text + metadata。
    /// - Stub：不调网络，echo + prefix
    /// - AI provider（stub）：抛 ProviderError.notImplemented（不调真网络）
    /// - Throws: ProviderError
    func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult
}

// MARK: - SelectionActionKind

/// 5 个 selection action。raw value 跟 spec §3.1 一致（小写）。
public enum SelectionActionKind: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case translate
    case explain
    case summarize
    case rewrite
    case ask
}

// MARK: - TextCompletionRequest / Result

/// TextProvider.complete 输入。
/// - action: 5 个 action 之一
/// - selectedText: 用户选中的文本（**不**做 trim；调用方负责）
/// - appContext: frontmost app 上下文（无 Accessibility 权限时可能为 nil）
/// - petID: 可选；用于 provider 内部 cross-ref（与 petProfile 一致；**不**参与 prompt）
///   P2-L-3 之后仍保留，便于 provider 内部 logging / 路由。
/// - petProfile: 可选；pet 人设摘要 — PromptBuilder 用来在 system prompt 注入
///   humor / story 通道。**不**传时（首次启动还没选 pet）走通用 "helpful assistant" 系统提示。
/// - model: 可选 model override；nil 时 provider 用自己 default
public struct TextCompletionRequest: Sendable, Codable, Equatable {
    public let action: SelectionActionKind
    public let selectedText: String
    public let appContext: AppContextSnapshot?
    public let petID: String?
    public let petProfile: PetProfileSummary?
    public let model: String?

    public init(
        action: SelectionActionKind,
        selectedText: String,
        appContext: AppContextSnapshot? = nil,
        petID: String? = nil,
        petProfile: PetProfileSummary? = nil,
        model: String? = nil
    ) {
        self.action = action
        self.selectedText = selectedText
        self.appContext = appContext
        self.petID = petID
        self.petProfile = petProfile
        self.model = model
    }
}

/// TextProvider.complete 输出。
/// - providerID: 调用方实际用的 provider（用于 generation history / debug）
/// - modelUsed: provider 实际用的 model（可能 = request.model 或 provider default）
/// - tokensUsed: 可选；stub 是 nil
/// - latencyMS: provider 自报耗时（stub 是模拟 50-200ms）
public struct TextCompletionResult: Sendable, Codable, Equatable {
    public let text: String
    public let providerID: String
    public let modelUsed: String
    public let tokensUsed: Int?
    public let latencyMS: Int

    public init(
        text: String,
        providerID: String,
        modelUsed: String,
        tokensUsed: Int? = nil,
        latencyMS: Int
    ) {
        self.text = text
        self.providerID = providerID
        self.modelUsed = modelUsed
        self.tokensUsed = tokensUsed
        self.latencyMS = latencyMS
    }
}

// MARK: - AppContextSnapshot

/// App 上下文快照 — 触发层（P2-L-2）从 NSWorkspace.frontmostApplication 抓，
/// 作为 TextCompletionRequest.appContext 传给 provider。
///
/// **MVP 范围**（spec §1 P5 权限分层）：
///   - bundleID: NSWorkspace.frontmostApplication.bundleIdentifier（有；无 frontmost 时 nil）
///   - appName: localizedName（fallback "Unknown"）
///   - windowTitle: **MVP 不读**（避免偷偷抓窗口标题；Layer 2 Accessibility 留给 P2-M）
///   - capturedAt: 抓取时刻
///
/// 等价 + Sendable + Codable —— UI 可以在 Send 预览里直接展示。
public struct AppContextSnapshot: Sendable, Codable, Equatable, Hashable {
    public let bundleID: String?
    public let appName: String
    public let windowTitle: String?
    public let capturedAt: Date

    public init(
        bundleID: String?,
        appName: String,
        windowTitle: String? = nil,
        capturedAt: Date
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.capturedAt = capturedAt
    }
}

// MARK: - ProviderError

/// TextProvider 调用层错误。UI 层根据 case 显示对应文案（spec §3.1 P4 诚实感知）。
///
/// P2-L-3 扩：加 `.rateLimited` case + `.userMessage` 静态方法。
///   - `.rateLimited`：provider 显式 429 — UI 用友好文案（不是 debug 文案）
///   - `.userMessage(for:)` 把所有 case 翻译成**直接可显示**给用户的文本，
///     避免 UI 重复定义文案（spec P4 诚实感知）
public enum ProviderError: Error, CustomStringConvertible, Equatable {
    /// 找不到 provider（id 没注册）
    case providerNotFound(id: String)
    /// provider 需要 API key 但 keychain 找不到
    case keyMissing(providerID: String)
    /// provider 显式拒绝（safety filter / content filter）
    case contentRefused(reason: String)
    /// provider 显式 429 — rate limited
    case rateLimited(reason: String)
    /// provider 网络 / transport 失败
    case networkError(reason: String)
    /// provider 还在 stub 阶段，没接真实现
    case notImplemented(providerID: String, message: String)
    /// provider 抛了不属于以上任何类的错误
    case unknown(reason: String)

    public var description: String {
        switch self {
        case .providerNotFound(let id):
            return "ProviderError: provider '\(id)' not found"
        case .keyMissing(let id):
            return "ProviderError: provider '\(id)' requires API key but keychain has none"
        case .contentRefused(let r):
            return "ProviderError: content refused — \(r)"
        case .rateLimited(let r):
            return "ProviderError: rate limited — \(r)"
        case .networkError(let r):
            return "ProviderError: network error — \(r)"
        case .notImplemented(let id, let m):
            return "ProviderError: provider '\(id)' not implemented — \(m)"
        case .unknown(let r):
            return "ProviderError: unknown — \(r)"
        }
    }

    /// 翻译成**直接可显示**给用户的友好文案（spec §3.1 P4 诚实感知）。
    ///
    /// 契约：
    ///   - 返回的字符串**不**含 "ProviderError:" 前缀（**不**是 debug 文案）
    ///   - 含 emoji 时**不**夹 raw reason（reason 可能含 PII / URL token；spec P3 隐私）
    ///   - keyMissing / notImplemented 等有明确用户动作的，给出动作指引
    ///
    /// 注：UI 端 `SelectionCoordinator` 仍可继续用自己的文案（兼容旧路径）；
    /// 这个方法是 spec 标准的"中心文案"，用于 P2-N cache UI / P2-M Accessibility 等。
    public var userMessage: String {
        switch self {
        case .keyMissing:
            return "🔑 Provider requires an API key. Configure it in Settings."
        case .rateLimited:
            return "Provider is rate-limited. Please try again in a few seconds."
        case .contentRefused:
            return "Provider refused this content (likely safety filter)."
        case .notImplemented:
            return "This provider is not yet wired. Switch to Stub in the dropdown."
        case .providerNotFound(let id):
            return "Provider '\(id)' is not registered."
        case .networkError:
            return "Provider error: network"
        case .unknown:
            return "Provider error: unknown"
        }
    }
}

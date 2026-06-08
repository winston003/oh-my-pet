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
/// - petID: 可选；用于 prompt 注入 pet 人设（humor/story）。P2-L-3 会扩展
/// - model: 可选 model override；nil 时 provider 用自己 default
public struct TextCompletionRequest: Sendable, Codable, Equatable {
    public let action: SelectionActionKind
    public let selectedText: String
    public let appContext: AppContextSnapshot?
    public let petID: String?
    public let model: String?

    public init(
        action: SelectionActionKind,
        selectedText: String,
        appContext: AppContextSnapshot? = nil,
        petID: String? = nil,
        model: String? = nil
    ) {
        self.action = action
        self.selectedText = selectedText
        self.appContext = appContext
        self.petID = petID
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
public enum ProviderError: Error, CustomStringConvertible, Equatable {
    /// 找不到 provider（id 没注册）
    case providerNotFound(id: String)
    /// provider 需要 API key 但 keychain 找不到
    case keyMissing(providerID: String)
    /// provider 显式拒绝（rate limit / safety filter / content filter）
    case contentRefused(reason: String)
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
        case .networkError(let r):
            return "ProviderError: network error — \(r)"
        case .notImplemented(let id, let m):
            return "ProviderError: provider '\(id)' not implemented — \(m)"
        case .unknown(let r):
            return "ProviderError: unknown — \(r)"
        }
    }
}

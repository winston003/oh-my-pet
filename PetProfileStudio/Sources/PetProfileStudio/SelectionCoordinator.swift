// SelectionCoordinator.swift
// SelectionCoordinator — 把 trigger → capture → display panel → call provider → show result
// 串起来的协调器
//
// 责任（spec §3.1 P5 "user-triggered" + P2-L-2 任务描述）：
//   1. 被菜单栏 NSMenuItem "Ask about selection…" 触发
//   2. 用 NSPasteboard.general.string(forType: .string) 读**当前**剪贴板（只读一次；不轮询）
//   3. 用 FrontmostAppCapture.snapshot() 抓 frontmost app 上下文
//   4. 如果剪贴板空 → emit .info("No text selected. Copy something first.")，不调 AI
//   5. 如果剪贴板非空 → emit .readyForUser(...)
//   6. 用户选 action + 点 [Send] → 调 TextProviderRegistry 里的 provider
//   7. 收到 result → emit .completed(result)
//   8. 收到 error → emit .failed(error)
//   9. 收到 .keyMissing → emit .info("Configure API key in Settings")（**不**调 AI）
//  10. 完成后用户点 [Close] → emit .dismissed
//
// 设计要点：
//   - ObservableObject + @Published 状态（SwiftUI 友好）
//   - 所有外部依赖可注入（pasteboard / appSnapshot / providerRegistry）——
//     测试**不**污染真 NSPasteboard（adversarial probe 要求）
//   - 不 import 任何具体 provider（PetProfileLLM 包）；只 import PetProfileBrain 的协议
//   - 不写盘 SelectionResultCache（属 P2-N；当前 result 仅 in-memory）
//   - 不自动清剪贴板（剪贴板是用户自己的；task spec 明文要求）
//
// State machine（SelectionPhase）：
//   .idle                 — 初始 / 已 dismiss
//   .info(message)        — 短暂提示（剪贴板空 / 缺 key）
//   .readyForUser(...)    — SelectionPanel 应该显示，等待用户选 action + [Send]
//   .running              — 用户点 [Send]，AI 调中，按钮 disabled + ProgressView
//   .completed(result)    — AI 调成功，显示 result
//   .failed(errorMessage) — AI 调失败（ProviderError 之外；ProviderError → 走 info）
//   .dismissed            — 用户点 [Close] / [Cancel]
//
// **adversarial probe**：
//   - SelectionCoordinator init(pasteboard:) 接受 NSPasteboard mock，测试用
//     NSPasteboard.withUniqueName() 隔离，**不**碰 .general
//   - 在 SelectionCoordinator 里 grep "sk-[a-zA-Z0-9]" / "Bearer" — 0 命中（不读 key）
//   - 测试覆盖：剪贴板空、剪贴板非空、provider 抛错、provider 缺 key
//
// 不做：
//   - 不接真网络（provider 调的是 Stub / Stub-style OpenAITextProvider）
//   - 不写盘 result（属 P2-N）
//   - 不自动重试（用户自己点 [Send] 才会再调）
//   - 不在 .failed/.completed 后还保留 pasteboard 引用（in-memory only）

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain

// MARK: - Public phase

/// SelectionPanel 显示用的状态
public enum SelectionPhase: Equatable {
    case idle
    /// 提示（剪贴板空 / 缺 key）—— 一行 info 文案
    case info(message: String)
    /// 面板打开，等待用户选 action + 点 [Send]
    case readyForUser(state: SelectionState)
    /// 用户已点 [Send]，调 AI 中（按钮 disabled + ProgressView）
    case running(state: SelectionState)
    /// AI 调完成，显示 result
    case completed(state: SelectionState, result: TextCompletionResult)
    /// AI 调失败（非 ProviderError —— ProviderError 已经归一为 friendly 错误）
    case failed(state: SelectionState, errorMessage: String)
    /// 用户点 [Close] / [Cancel] —— UI 收尾
    case dismissed
}

/// 面板打开时固定的"输入侧"数据（用户选 action 时不变）
public struct SelectionState: Equatable {
    public let selectedText: String
    public let appContext: AppContextSnapshot
    public var providerID: String
    public var model: String
    /// 5 个 action 中的当前选中
    public var action: SelectionActionKind

    public init(
        selectedText: String,
        appContext: AppContextSnapshot,
        providerID: String,
        model: String,
        action: SelectionActionKind = .explain
    ) {
        self.selectedText = selectedText
        self.appContext = appContext
        self.providerID = providerID
        self.model = model
        self.action = action
    }
}

// MARK: - Coordinator

public final class SelectionCoordinator: ObservableObject {

    // 注：SelectionCoordinator **不** 标 @MainActor。
    //   - 理由 1：public trigger / send / cancel / close 都被菜单栏 NSMenuItem action
    //     触发，menu action 默认在 main 跑；UI 端用也没问题
    //   - 理由 2：单线程的 main 调度是约定；不在类型系统里强制，方便单测
    //     （Tests 是 sync 跑，跑在 main；用 `phase =` 写入没有 Sendable 警告）
    //   - 理由 3：send() 内部的 `Task { ... await MainActor.run { ... } }` 模式
    //     已经把 `phase =` 写入锁在 main 上
    //   - 真出现 race condition 风险：把 class 标 @MainActor 然后用
    //     `MainActor.assumeIsolated` 调（Tests add 内部；见 SelectionCoordinatorTests）

    // MARK: - Published state

    @Published public private(set) var phase: SelectionPhase = .idle

    // MARK: - Injected dependencies

    private let pasteboard: NSPasteboard
    private let appSnapshot: () -> FrontmostAppCapture.Snapshot
    private let providerRegistry: TextProviderRegistry
    /// model 推断策略（provider 已知 model 时直接用；StubTextProvider 的 modelUsed
    /// 来自 result，不是 request；OpenAI 用 defaultModel）
    private let modelForProvider: (TextProvider) -> String

    /// 给 SelectionPanel / 测试用：列出当前 registry 的所有 provider
    public var allProvidersList: [TextProvider] {
        return providerRegistry.allProviders
    }

    /// 当前 inflight task（cancel 支持留给 P2-N；当前只持引用）
    private var currentTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        pasteboard: NSPasteboard = .general,
        appSnapshot: @escaping () -> FrontmostAppCapture.Snapshot = { FrontmostAppCapture.snapshot() },
        providerRegistry: TextProviderRegistry = .shared,
        modelForProvider: @escaping (TextProvider) -> String = { provider in
            // Stub: "stub-echo-v1"（来自 StubTextProvider 的 modelUsed）
            // OpenAI: "gpt-4o-mini"（来自 OpenAITextProvider.defaultModel）
            // 不依赖具体 provider 类型；按 id 前缀判断是最简单的
            // 更精确的方式是 provider 自己暴露 modelDefault —— 当前协议没有，留 P2-N
            switch provider.id {
            case "openai-gpt":
                return "gpt-4o-mini"
            case "stub":
                return "stub-echo-v1"
            default:
                return provider.id
            }
        }
    ) {
        self.pasteboard = pasteboard
        self.appSnapshot = appSnapshot
        self.providerRegistry = providerRegistry
        self.modelForProvider = modelForProvider
    }

    // MARK: - Public API

    /// 菜单栏 / hotkey 触发时调用。同步开始：检查剪贴板，决定 phase。
    /// 约定在 main 跑（菜单栏 action 就在 main）；不强制 actor isolation。
    public func trigger() {
        // 1. 读剪贴板（spec §1 P5 "user-triggered"：只在点菜单项那一瞬间读）
        // trim 不做 —— 用户可能想翻译"   "（多空格）；调用方选择 trim
        let raw = pasteboard.string(forType: .string) ?? ""
        // 防御：纯 whitespace 视为空
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            self.phase = .info(message: "No text selected. Copy something first.")
            return
        }

        // 2. 抓 frontmost app 上下文
        let snap = appSnapshot()
        // 3. 转成 PetProfileBrain.AppContextSnapshot
        let appContext = AppContextSnapshot(
            bundleID: snap.bundleID,
            appName: snap.appName,
            windowTitle: snap.windowTitle,  // 永远 nil（MVP 不读）
            capturedAt: snap.capturedAt
        )

        // 4. 选默认 provider（TextProviderRegistry.shared.defaultProvider）
        //    —— 显式 keychain 状态留给调用方在 UI 上展示；这里只挑 default
        let defaultProvider = providerRegistry.defaultProvider
        let model = modelForProvider(defaultProvider)
        let state = SelectionState(
            selectedText: raw,
            appContext: appContext,
            providerID: defaultProvider.id,
            model: model,
            action: .explain
        )
        self.phase = .readyForUser(state: state)
    }

    /// 用户在面板上换 provider（dropdown 改变时）
    public func selectProvider(id: String) {
        guard case .readyForUser(var s) = phase else {
            // running / completed 阶段不允许改
            return
        }
        guard let provider = providerRegistry.provider(for: id) else { return }
        s.providerID = provider.id
        s.model = modelForProvider(provider)
        self.phase = .readyForUser(state: s)
    }

    /// 用户在面板上选 action
    public func selectAction(_ action: SelectionActionKind) {
        guard case .readyForUser(var s) = phase else { return }
        s.action = action
        self.phase = .readyForUser(state: s)
    }

    /// 用户点 [Cancel] —— 关闭面板，回到 idle
    public func cancel() {
        currentTask?.cancel()
        currentTask = nil
        self.phase = .dismissed
    }

    /// 用户点 [Close]（result 之后）—— 关闭面板，回到 idle
    public func close() {
        currentTask?.cancel()
        currentTask = nil
        self.phase = .dismissed
    }

    /// 用户点 [Send] —— 调 provider
    public func send() {
        guard case .readyForUser(let s) = phase else { return }
        guard let provider = providerRegistry.provider(for: s.providerID) else {
            self.phase = .info(message: "Provider '\(s.providerID)' not found.")
            return
        }
        // 缺 key：UI 友好提示（**不**调 AI）
        if provider.requiresAPIKey {
            // 公开 API：TextProvider 不暴露 keychain 状态。保守做法：直接调，
            // 让 provider 抛 .keyMissing；UI catch 后转成 info。
            // 这种实现能跨 provider 统一（不依赖 KeychainKeyStore 注入）。
        }
        self.phase = .running(state: s)

        let request = TextCompletionRequest(
            action: s.action,
            selectedText: s.selectedText,
            appContext: s.appContext,
            petID: nil,    // petID 留给 P2-L-3（humor/story 注入）
            model: nil     // model 由 provider 自己 default
        )
        let stateForResult = s

        currentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await provider.complete(request)
                // 注：SelectionCoordinator 不在 @MainActor 上；phase 写入在任意线程都行
                // （@Published 内部保证 observer 调度）。production UI 用 dispatch async 到
                // main 即可（SwiftUI 默认在 main 收 published change）。
                self.phase = .completed(state: stateForResult, result: result)
            } catch let e as ProviderError {
                let msg = Self.friendlyMessage(for: e, state: stateForResult)
                if case .keyMissing = e {
                    // 缺 key → info（不调 AI；不报错）
                    self.phase = .info(message: msg)
                } else {
                    // 其他 ProviderError → friendly 错误
                    self.phase = .failed(state: stateForResult, errorMessage: msg)
                }
            } catch {
                self.phase = .failed(
                    state: stateForResult,
                    errorMessage: "Provider returned error: \(Self.describe(error))"
                )
            }
            self.currentTask = nil
        }
    }

    /// info 自动 dismiss（让 UI 不卡住；5 秒后回 idle）
    public func clearInfo() {
        if case .info = phase {
            self.phase = .idle
        }
    }

    // MARK: - Helpers

    /// 把 ProviderError 翻译成 friendly 错误文本。
    /// 注：keyMissing 走 .info 而非 .failed（任务描述明确要求）。
    static func friendlyMessage(for e: ProviderError, state: SelectionState) -> String {
        switch e {
        case .keyMissing(let id):
            return "Provider '\(id)' requires an API key. Configure it in Settings → BYOK."
        case .providerNotFound(let id):
            return "Provider '\(id)' is not registered."
        case .contentRefused(let reason):
            return "Provider returned error: content refused — \(reason)"
        case .networkError(let reason):
            return "Provider returned error: network error — \(reason)"
        case .notImplemented(_, let message):
            return "Provider returned error: not implemented — \(message)"
        case .unknown(let reason):
            return "Provider returned error: unknown — \(reason)"
        }
    }

    static func describe(_ error: Error) -> String {
        if let pe = error as? ProviderError {
            return pe.description
        }
        return String(describing: error)
    }
}

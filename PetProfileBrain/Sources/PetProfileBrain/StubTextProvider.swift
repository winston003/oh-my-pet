// StubTextProvider.swift
// StubTextProvider — 默认 text provider。Echo + prefix，**不**走网络。
//
// 行为（spec §3.1 + 任务描述）：
//   1. 支持全部 5 个 SelectionActionKind（translate / explain / summarize / rewrite / ask）
//   2. 输出格式：把 request 字段格式化成 "echo + prefix"，便于测试断言 + UI 调试
//      - translate → "[STUB translate from {appContext.appName}]: {selectedText}"
//      - explain   → "[STUB explain]: {selectedText}"
//      - summarize → "[STUB summarize]: {selectedText}"
//      - rewrite   → "[STUB rewrite]: {selectedText}"
//      - ask       → "[STUB ask in {appContext.appName}]: {selectedText}"
//   3. latency 模拟 50-200ms（random Task.sleep）
//   4. 每次 complete 内部 print 一次到 stderr：provider id + action + 截断 80 字符的
//      selectedText（**不** print key / 完整 selectedText > 80 字符 / petID / model）
//   5. appContext 为 nil 时也能跑（fallback 到 "unknown app"）—— 不能 crash
//
// test isolation：
//   - struct / Sendable 即可（无 in-memory mutable state 跨 call 共享）
//   - 两次连续 complete 之间**不**应共享任何 state（每次都重新拼 string）
//   - latency 模拟用 Int.random 不需要 seed（没有可测的统计属性）
//
// 不做：
//   - 不接 AI API（这是 stub 的契约）
//   - 不缓存响应（违反 fresh-生成原则；AGENTS.md "Local-First And BYOK"）
//   - 不持久化调用历史（属 P2-N SelectionResultCache）
//   - 不读真剪贴板 / 屏幕（属 P2-L-2 SelectionTrigger / FrontmostAppCapture）
//   - 不 import AppKit（Core 层；UI / Cocoa 留给 P2-L-2）
//

import Foundation

// MARK: - StubTextProvider

/// Stub TextProvider — 默认实现，echo + prefix。
///
/// 构造时无依赖（默认 key 注入与否都不影响行为；isKeyConfigured 不读 keychain）。
public struct StubTextProvider: TextProvider {

    public static let providerID: String = "stub"

    public let id: String = StubTextProvider.providerID
    public let displayName: String = "Stub"
    public let requiresAPIKey: Bool = false

    /// 支持全部 5 个 action
    public let supportedActions: Set<SelectionActionKind> = Set(SelectionActionKind.allCases)

    /// 用于模拟延迟的最小 / 最大毫秒（test 可调到 0 加速）
    public let minLatencyMS: Int
    public let maxLatencyMS: Int

    /// 默认构造：50-200ms 模拟延迟
    public init(minLatencyMS: Int = 50, maxLatencyMS: Int = 200) {
        self.minLatencyMS = minLatencyMS
        self.maxLatencyMS = maxLatencyMS
    }

    // MARK: - TextProvider

    public func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult {
        let start = Date()
        // 1. 模拟延迟（50-200ms，可注入范围；min == max 时直接 sleep）
        if maxLatencyMS > 0 {
            let ms = Int.random(in: minLatencyMS...maxLatencyMS)
            try await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
        }

        // 2. 拼 echo + prefix
        let appName = request.appContext?.appName ?? "unknown app"
        let text = Self.makeStubText(action: request.action, appName: appName, selectedText: request.selectedText)

        // 3. 截断 80 字符的 selectedText print（**不** print 完整 selectedText / petID / model）
        let preview = String(request.selectedText.prefix(80))
        FileHandle.standardError.write(Data(
            "[StubTextProvider] id=\(id) action=\(request.action.rawValue) textPreview=\"\(preview)\"\n".utf8
        ))

        // 4. 算 latency（包含 sleep 的真实时间）
        let latency = Int(Date().timeIntervalSince(start) * 1000)

        // 5. 构造 result
        // modelUsed：stub 用 "stub-echo-v1"（不读 request.model —— 显式 override 也不影响 stub 行为）
        return TextCompletionResult(
            text: text,
            providerID: id,
            modelUsed: "stub-echo-v1",
            tokensUsed: nil,
            latencyMS: latency
        )
    }

    // MARK: - 内部 helper（test 也可直接调）

    /// 拼 stub 输出文本。**不**读网络，不修改 state。
    static func makeStubText(
        action: SelectionActionKind,
        appName: String,
        selectedText: String
    ) -> String {
        switch action {
        case .translate:
            return "[STUB translate from \(appName)]: \(selectedText)"
        case .explain:
            return "[STUB explain]: \(selectedText)"
        case .summarize:
            return "[STUB summarize]: \(selectedText)"
        case .rewrite:
            return "[STUB rewrite]: \(selectedText)"
        case .ask:
            return "[STUB ask in \(appName)]: \(selectedText)"
        }
    }
}

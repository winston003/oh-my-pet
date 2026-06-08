// OpenAITextProvider.swift
// OpenAITextProvider — OpenAI GPT 文本生成的 stub 实现
//
// 对应 spec §3.1 TextProvider 的 AI provider 钩子。
//
// 关键约束（spec §3.1 "禁止调用方 import 具体 SDK"）：
//   - **不** import "OpenAI" / "OpenAIKit" / "OpenAISwift" / "SwiftOpenAI" 等具体 SDK
//   - **不** 直接调 https://api.openai.com/v1/chat/completions
//   - **不** 持有硬编码 API key（走 KeychainKeyStore；keychain 找不到 → 抛 .keyMissing）
//   - 当前阶段 complete() 抛 ProviderError.notImplemented（带 marker 文本到 stderr）
//
// 真正的 OpenAI HTTP 接入留给后续 P2-N：届时本文件被替换为真 HTTP provider，
// 仍复用同协议 + KeychainKeyStore。
//
// 设计要点：
//   - struct + Sendable（无 in-memory mutable state）
//   - supportedActions 全 5 个（与 Stub 对齐；后续真接入时可缩）
//   - id = "openai-gpt"（UI 列表用）
//   - displayName = "OpenAI GPT"
//   - requiresAPIKey = true
//   - init 接受 KeychainKeyStore 注入（默认 .shared）—— 测试可注入 in-memory backend
//   - init 接受可选 keychainAccount 名字（默认 = id = "openai-gpt"）
//
// **keychain account 命名规范**：
//   - account = provider.id（"openai-gpt"），跟 PetProfileLLM 既有 LLMProvider
//     区分（既有 OpenAIProvider 用 account "openai"；这里"openai-gpt"是 TextProvider 的
//     account 名字，跟 LLM 链路独立 —— 避免命名冲突）
//   - 跟 OpenAIProvider 的 keychain account 不共用，**避免**未来 HTTP 接错到对方 key
//
// 不做：
//   - 不调真网络（stub 阶段）
//   - 不引入第三方 SDK
//   - 不在 init 里 read keychain（lazy：complete 时再 read；这样测试不污染 keychain）
//   - 不缓存任何响应
//

import Foundation
import PetProfileBrain

// MARK: - OpenAITextProvider

public struct OpenAITextProvider: TextProvider, @unchecked Sendable {

    public static let providerID: String = "openai-gpt"
    public static let defaultModel: String = "gpt-4o-mini"

    public let id: String = OpenAITextProvider.providerID
    public let displayName: String = "OpenAI GPT"
    public let requiresAPIKey: Bool = true

    /// 支持全部 5 个 action（与 Stub 对齐；后续真接入时可缩）
    public let supportedActions: Set<SelectionActionKind> = Set(SelectionActionKind.allCases)

    /// 可注入的 KeychainKeyStore（默认 .shared）。测试用 InMemoryKeychainBackend 注入。
    public let keychain: KeychainKeyStore

    /// model override（nil 时用 defaultModel）
    public let model: String

    /// Keychain 账户名（默认 = id，即 "openai-gpt"）
    public let keychainAccount: String

    public init(
        keychain: KeychainKeyStore = .shared,
        model: String? = nil,
        keychainAccount: String? = nil
    ) {
        self.keychain = keychain
        self.model = model ?? OpenAITextProvider.defaultModel
        self.keychainAccount = keychainAccount ?? OpenAITextProvider.providerID
    }

    // MARK: - TextProvider

    public func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult {
        // 1. 检查 keychain 是否有 key
        let key: String
        do {
            guard let k = try keychain.loadKey(forProvider: keychainAccount), !k.isEmpty else {
                throw ProviderError.keyMissing(providerID: id)
            }
            key = k
        } catch let e as ProviderError {
            throw e
        } catch {
            throw ProviderError.networkError(reason: "keychain load failed: \(error)")
        }

        // 2. 跑 PromptBuilder 编排 system + user（P2-L-3：pet 人设注入）
        //    真 OpenAI HTTP 接入时（P2-N），把 prompt.system + prompt.user 序列化进
        //    /v1/chat/completions body 的 messages 数组（system + user role）。
        //    当前 stub 阶段：把 prompt 拼到 input 字段，便于 verifier / debug 看到 pet 人设真在用。
        let prompt = PromptBuilder.buildSelectionPrompt(request: request, pet: request.petProfile)

        // 3. stub 阶段：调任何请求都抛 notImplemented。
        //    先把"会返回的 text"打到 stderr 便于调试（**不** print key / petID / model），
        //    text 字段仍生成一份"echo + prefix"（同形 StubTextProvider），便于
        //    P2-L-2 UI 看到 marker 后能给出"Switch to Stub"的友好提示。
        let appName = request.appContext?.appName ?? "unknown app"
        let wouldBeText = "[OpenAI STUB — not wired yet] [\(request.action.rawValue) from \(appName)]: \(request.selectedText)"

        // 4. 截断 80 字符的 selectedText print（**不** print key / 完整 selectedText > 80 字符 /
        //    system prompt 全文 / user prompt 全文 — system prompt 可能含人设 PII）
        let preview = String(request.selectedText.prefix(80))
        // keyPrefix 仅显示前 7 字符（"sk-xxxx..."），便于确认 key 加载到了
        let keyPrefix = String(key.prefix(7))
        let petTag = request.petProfile.map { " pet=\($0.name)/\($0.humorStyle)" } ?? ""
        FileHandle.standardError.write(Data(
            "[OpenAITextProvider] id=\(id) action=\(request.action.rawValue)\(petTag) textPreview=\"\(preview)\" keyPrefix=\"\(keyPrefix)\" wouldBeText=\"\(wouldBeText.prefix(120))\"\n".utf8
        ))

        // 5. 抛 notImplemented —— UI 收到后用 ProviderError.userMessage 显示
        //    "This provider is not yet wired. Switch to Stub in the dropdown."
        throw ProviderError.notImplemented(
            providerID: id,
            message: "OpenAITextProvider.complete — real HTTP call not wired in P2-L-1; would use prompt.system=\(prompt.system.prefix(60))... prompt.user=\(prompt.user.prefix(60))...; would return: \(wouldBeText.prefix(120))"
        )
    }
}

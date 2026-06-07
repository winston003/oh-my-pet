// RealLLMFactory.swift
// 真 LLM provider 工厂 — 按 provider 名字路由到 OpenAI / Claude / OpenAI-compatible
//
// provider 名字约定（跟 KeychainKeyStore 的 account 名保持一致）：
//   - "openai"                        → OpenAIProvider
//   - "claude"                        → ClaudeProvider
//   - "openai-compatible:<endpoint>"  → OpenAICompatibleProvider（Ollama / LM Studio / vLLM）
//
// 模型选择：
//   - "openai"  → default `gpt-4o-mini`
//   - "claude"  → default `claude-3-5-haiku-20241022`
//   - "openai-compatible:<endpoint>" → **没有 default**（caller 必须通过 `model:` 传入）
//
// Keychain 行为：
//   - "openai" / "claude" → 必须 keychain 里有 key
//   - "openai-compatible:<endpoint>" → keychain 里的 key **可选**（Ollama / LM Studio 本地
//     服务可能不需 auth）。factory 默认会传 `apiKey: nil`，但如果 keychain 里存了就用存的那条
//
// 错误：
//   - provider name 不识别 → RealLLMError.unknownProvider
//   - 必填 keychain 找不到 key → .unauthorized（不是 RealLLMError；直接抛 LLMError.unauthorized
//     让上层一致处理）
//
// 不做：
//   - 不做 model 名字注册表（spec 没要求；以后加 userConfig 时再补）
//   - 不做 env 变量 lookup（AGENTS.md "Local-First And BYOK" 不允许）
//

import Foundation

// MARK: - RealLLMError

public enum RealLLMError: Error, CustomStringConvertible, Equatable {
    /// provider 名字不识别
    case unknownProvider(name: String)
    /// openai-compatible 必须显式传 model
    case modelRequired(provider: String)
    /// Keychain 抛的非 -25300 错
    case keychainError(reason: String)

    public var description: String {
        switch self {
        case .unknownProvider(let n):
            return "RealLLMFactory: unknown provider '\(n)' (expected 'openai' / 'claude' / 'openai-compatible:<endpoint>')"
        case .modelRequired(let p):
            return "RealLLMFactory: '\(p)' requires explicit model (no default for local endpoints)"
        case .keychainError(let r):
            return "RealLLMFactory: keychain error: \(r)"
        }
    }
}

// MARK: - RealLLMFactory

public final class RealLLMFactory {

    private let keychain: KeychainKeyStore

    public init(keychain: KeychainKeyStore) {
        self.keychain = keychain
    }

    /// 便捷 static 方法（用 `KeychainKeyStore.shared`，即真 keychain）。
    /// - Parameter provider: "openai" / "claude" / "openai-compatible:<endpoint>"
    /// - Parameter model: 可选；不传走 default
    public static func create(
        provider: String,
        model: String? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 30
    ) throws -> AsyncLLMProvider {
        return try RealLLMFactory(keychain: .shared).create(
            provider: provider, model: model, session: session, timeout: timeout
        )
    }

    /// 注入式 create（测试可换 mock keychain / mock session）。
    public func create(
        provider: String,
        model: String? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 30
    ) throws -> AsyncLLMProvider {
        switch provider {
        case "openai":
            let key = try loadKeyOrThrow(provider: "openai")
            return OpenAIProvider(
                apiKey: key,
                model: model ?? "gpt-4o-mini",
                session: session,
                timeout: timeout
            )
        case "claude":
            let key = try loadKeyOrThrow(provider: "claude")
            return ClaudeProvider(
                apiKey: key,
                model: model ?? "claude-3-5-haiku-20241022",
                session: session,
                timeout: timeout
            )
        default:
            if provider.hasPrefix("openai-compatible:") {
                let endpointStr = String(provider.dropFirst("openai-compatible:".count))
                guard let endpoint = URL(string: endpointStr) else {
                    throw RealLLMError.unknownProvider(name: provider)
                }
                guard let m = model, !m.isEmpty else {
                    throw RealLLMError.modelRequired(provider: provider)
                }
                // keychain 里的 key 是可选的 — Ollama / LM Studio 本地服务可能不需 auth
                let key = (try? keychain.loadKey(forProvider: provider)) ?? nil
                return OpenAICompatibleProvider(
                    endpoint: endpoint,
                    apiKey: key,
                    model: m,
                    session: session,
                    timeout: timeout
                )
            }
            throw RealLLMError.unknownProvider(name: provider)
        }
    }

    // MARK: - helpers

    /// 加载 key；找不到 → 抛 LLMError.unauthorized（让上层 UI 走"请填 key"分支）
    private func loadKeyOrThrow(provider: String) throws -> String {
        do {
            guard let key = try keychain.loadKey(forProvider: provider), !key.isEmpty else {
                throw LLMError.unauthorized
            }
            return key
        } catch let kerr as KeychainError {
            throw RealLLMError.keychainError(reason: String(describing: kerr))
        }
    }
}

// MARK: - 已知 provider 名字常量

public enum RealLLMProviderName {
    public static let openai = "openai"
    public static let claude = "claude"
    public static let openaiCompatiblePrefix = "openai-compatible:"
}

// LLMProvider.swift
// LLM 抽象层 — 协议 + 错误类型
//
// 设计要点：
//   - 协议只暴露「输入 prompt → 输出原始 LLM 文本」一个能力
//     不在这里塞 provider/model/Keychain（那是 P2-D 范围）
//   - mock LLM（fixture）走 MockLLM impl；真 provider 接入 P2-D 再补 OpenAILLM / ClaudeLLM
//   - complete() 是同步：测试和 mock LLM 不需要 async；以后真 provider 可加 async 版本
//   - LLMError 暴露"output not parseable"等关键错误给上层 Brain 决策
//

import Foundation

// MARK: - LLMProvider protocol

/// LLM 抽象层。Brain 只看 prompt → raw text 文本，
/// 不关心是 mock / OpenAI / Claude / 本地模型。
///
/// 实现要点：
///   - **不允许抛 network / parse 错**（raw text 解析是 Brain 的事，不是 LLM 的事）
///   - 实现负责把 prompt 拼成 provider 请求，吐回原始 response text
///   - 失败抛 `LLMError.transportFailed` / `LLMError.emptyResponse`
public protocol LLMProvider {
    /// 同步调 LLM，返回原始 response text（不解析）
    /// - Throws: LLMError
    func complete(prompt: String) throws -> String
}

// MARK: - LLMError

/// LLM 调用层的错误。Brain 捕获后可以降级（重试 / 走 default / 上报）。
public enum LLMError: Error, CustomStringConvertible, Equatable {
    /// provider 网络层 / transport 失败
    case transportFailed(reason: String)
    /// 返回为空（mock LLM 不抛；真 provider 可能抛）
    case emptyResponse
    /// provider 返回的内容无法被 Brain 解析为 BrainResponse JSON
    case malformedResponse(rawText: String)
    /// provider 显式拒绝了请求（rate limit / safety）
    case rejected(reason: String)

    public var description: String {
        switch self {
        case .transportFailed(let r): return "LLM transport failed: \(r)"
        case .emptyResponse: return "LLM returned empty response"
        case .malformedResponse(let raw): return "LLM response malformed: \(raw.prefix(120))"
        case .rejected(let r): return "LLM rejected request: \(r)"
        }
    }
}

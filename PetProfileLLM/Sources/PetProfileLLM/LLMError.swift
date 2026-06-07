// LLMError.swift
// PetProfileLLM 错误类型 + 错误恢复策略常量
//
// 设计决策：
//   - **5 类错误**（按 spec）：
//     1. networkError(underlying:)    — URLSession transport 失败；触发 1 次重试
//     2. unauthorized                 — 401；不重试，导用户去检查 key
//     3. rateLimited(retryAfter:)     — 429；不重试，暴露 retry-after header 给 UI
//     4. serverError(statusCode:)     — 5xx；不重试（除 5xx 内的 502/503/504 也不重试，
//                                       真要"自动重试"应该是上层加退避）
//     5. timeout                      — URLSession 超时（默认 30s）
//     + invalidResponse              — 解析失败（HTTP 200 但 body 损坏 / 缺字段）
//   - 跟 PetProfileBrain.LLMError 是**同名不同模块**：
//     Brain.LLMError 描述"解析失败 / mock 行为"；本枚举描述"transport / HTTP 状态"。
//     桥接：RealLLMFactory / SyncAdapter 把本枚举的 .networkError 翻译成 Brain 的
//     .transportFailed，让 Brain 的 fallback 决策（重试走 default、UI 提示）走 Brain 既有路径。
//   - 错误信息遵循"用户可见 = 短；开发者可见 = 全"分层：
//     - description 走 CustomStringConvertible，给 logger
//     - userFacingMessage 走 case-by-case 短文本，给 UI 提示
//
// 不做：
//   - 不做 i18n
//   - 不在这里塞 retry-after 行为（那是 provider 内部策略）
//

import Foundation

// MARK: - LLMError

public enum LLMError: Error, CustomStringConvertible, Equatable {

    /// URLSession transport 失败（DNS / 连接重置 / TLS / socket closed / NSURLError 全家）
    /// provider 实现层会先做 1 次重试（500ms backoff）；重试仍失败 → 抛
    case networkError(underlying: NSError)

    /// HTTP 401：API key 错 / 过期 / 被 revoke
    case unauthorized

    /// HTTP 429：rate limit
    /// - Parameter retryAfter: `Retry-After` header 解析出的等待秒数（可能为 nil）
    case rateLimited(retryAfter: TimeInterval?)

    /// HTTP 5xx：provider server 挂了
    /// - Parameter statusCode: 5xx 的具体状态码
    case serverError(statusCode: Int)

    /// URLSession 超时（默认 30s）
    case timeout

    /// HTTP 200 但 body 解析失败（缺字段 / 类型不匹配 / 不是 JSON）
    case invalidResponse(reason: String)

    // MARK: - description

    public var description: String {
        switch self {
        case .networkError(let e):
            return "LLM network error [domain=\(e.domain) code=\(e.code)]: \(e.localizedDescription)"
        case .unauthorized:
            return "LLM unauthorized (401): check your API key in Keychain"
        case .rateLimited(let r):
            if let r = r {
                return "LLM rate limited (429): retry after \(r)s"
            }
            return "LLM rate limited (429): no retry-after header"
        case .serverError(let code):
            return "LLM server error (\(code))"
        case .timeout:
            return "LLM request timed out"
        case .invalidResponse(let r):
            return "LLM invalid response: \(r)"
        }
    }

    // MARK: - user-facing message

    /// 给 UI 提示用（短，不含技术细节）。跟 description 解耦是为了不让 log 噪音进 UI。
    public var userFacingMessage: String {
        switch self {
        case .networkError:
            return "网络问题。检查连接后重试。"
        case .unauthorized:
            return "API key 失效。在设置里重新填一遍。"
        case .rateLimited(let r):
            if let r = r {
                return "调用太频繁，等 \(Int(r)) 秒再试。"
            }
            return "调用太频繁，稍后再试。"
        case .serverError:
            return "AI 服务暂时不可用，稍后再试。"
        case .timeout:
            return "请求超时，稍后再试。"
        case .invalidResponse:
            return "AI 返回了看不懂的内容。"
        }
    }

    // MARK: - 转换 helper

    /// 把 URLSession 的 URLError 转成 LLMError（统一收口）
    public static func map(urlError: Error) -> LLMError {
        let nsErr = urlError as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorTimedOut {
            return .timeout
        }
        return .networkError(underlying: nsErr)
    }
}

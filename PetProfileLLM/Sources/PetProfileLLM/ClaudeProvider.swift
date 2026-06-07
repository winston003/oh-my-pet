// ClaudeProvider.swift
// Anthropic Messages API 真 provider
//
// 协议：POST {baseURL}/v1/messages
//   Headers:
//     x-api-key: <apiKey>
//     anthropic-version: 2023-06-01
//     Content-Type: application/json
//   Body:
//     {
//       "model": "claude-3-5-haiku-20241022",
//       "max_tokens": 500,
//       "messages": [{"role": "user", "content": "<prompt>"}]
//     }
//   Response 200:
//     {"content": [{"type": "text", "text": "<text>"}]}
//
// 与 OpenAI 的关键差异：
//   - **没有 temperature 在 body 里**（spec 没要求；Anthropic Messages API 支持但
//     Brain 不会拼 — 由 caller 控；先不传）
//   - **`x-api-key` 头**（不是 `Authorization: Bearer`）
//   - **`anthropic-version` 头**（必须）
//   - **`max_tokens` 是必填**（Anthropic 不允许省略，OpenAI 也是必填但 spec 模板里有）
//   - response 是 `content: [{type: "text", text: "..."}]` 数组（可能多个 block）
//   - Anthropic **没有 system role** in messages 数组 — system prompt 走单独 `system` 字段。
//     Brain 把 system + user 拼成单 prompt 喂进来，所以这里**不**解析 system/user 分段。
//
// 错误映射：跟 OpenAI 一样（401 / 429 / 5xx / timeout / network / invalidResponse）
//
// 设计决策：
//   - `anthropic-version` 硬编码为 `2023-06-01`（Anthropic 文档里最稳的稳定值）
//   - content block 只取 type=="text" 的（忽略 type=="tool_use" 等 — spec 没要 tool calling）
//   - 多个 text block 用 `\n` 拼接
//

import Foundation

// MARK: - ClaudeProvider

public final class ClaudeProvider: AsyncLLMProvider {

    public let name: String = "claude"
    public let model: String
    public let baseURL: URL
    public let apiVersion: String

    private let apiKey: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let retryBaseDelay: TimeInterval

    public init(
        apiKey: String,
        model: String = "claude-3-5-haiku-20241022",
        baseURL: URL? = nil,
        apiVersion: String = "2023-06-01",
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        maxRetries: Int = 1,
        retryBaseDelay: TimeInterval = 0.5
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL ?? URL(string: "https://api.anthropic.com")!
        self.apiVersion = apiVersion
        self.session = session
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
    }

    // MARK: - AsyncLLMProvider

    public func complete(prompt: String) async throws -> String {
        let request = try buildRequest(prompt: prompt)
        let data = try await performWithRetry(request: request)
        return try parseResponse(data: data)
    }

    // MARK: - request 构造（internal 暴露给 test）

    func buildRequest(prompt: String) throws -> URLRequest {
        let url = baseURL.appendingPathComponent("/v1/messages")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 500,
            "messages": [
                ["role": "user", "content": prompt]
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    // MARK: - HTTP 执行 + 重试（跟 OpenAI 同形态）

    private func performWithRetry(request: URLRequest) async throws -> Data {
        var attempt = 0
        var lastError: Error?

        while attempt <= maxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.invalidResponse(reason: "response is not HTTPURLResponse")
                }
                try Self.validate(httpResponse: http, data: data)
                return data
            } catch let err as LLMError {
                switch err {
                case .unauthorized, .rateLimited, .serverError, .invalidResponse, .timeout:
                    throw err
                case .networkError:
                    lastError = err
                    attempt += 1
                    if attempt > maxRetries { throw err }
                    let delay = retryBaseDelay * pow(2.0, Double(attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                let mapped = LLMError.map(urlError: error)
                lastError = mapped
                attempt += 1
                if attempt > maxRetries { throw mapped }
                let delay = retryBaseDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? LLMError.invalidResponse(reason: "Claude performWithRetry exhausted")
    }

    // MARK: - HTTP 状态码 → LLMError

    static func validate(httpResponse: HTTPURLResponse, data: Data) throws {
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw LLMError.unauthorized
        case 429:
            let retryAfter: TimeInterval? = httpResponse.value(forHTTPHeaderField: "Retry-After").flatMap { raw in
                if let s = TimeInterval(raw) { return s }
                return nil
            }
            throw LLMError.rateLimited(retryAfter: retryAfter)
        case 500..<600:
            throw LLMError.serverError(statusCode: httpResponse.statusCode)
        default:
            throw LLMError.invalidResponse(reason: "unexpected status code \(httpResponse.statusCode)")
        }
    }

    // MARK: - 响应解析（internal 暴露给 test）

    func parseResponse(data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse(reason: "Claude response is not a JSON object")
        }
        guard let content = obj["content"] as? [[String: Any]], !content.isEmpty else {
            throw LLMError.invalidResponse(reason: "Claude response missing 'content' array")
        }
        // 收集所有 type=="text" 的 block，用 \n 拼接
        let texts: [String] = content.compactMap { block in
            guard let type = block["type"] as? String, type == "text" else { return nil }
            return block["text"] as? String
        }
        if texts.isEmpty {
            throw LLMError.invalidResponse(reason: "Claude response has no text blocks")
        }
        return texts.joined(separator: "\n")
    }
}

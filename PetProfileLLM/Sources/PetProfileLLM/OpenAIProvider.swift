// OpenAIProvider.swift
// OpenAI Chat Completions API 真 provider
//
// 协议：POST {baseURL}/v1/chat/completions
//   Headers:
//     Authorization: Bearer <apiKey>
//     Content-Type: application/json
//   Body:
//     {
//       "model": "gpt-4o-mini",
//       "messages": [{"role": "user", "content": "<prompt>"}],
//       "temperature": 0.7,
//       "max_tokens": 500
//     }
//   Response 200:
//     {"choices": [{"message": {"content": "<text>"}}]}
//
// 错误映射：
//   - 401 → .unauthorized
//   - 429 → .rateLimited(retry-after header)
//   - 5xx → .serverError(statusCode)
//   - URLSession transport 错 → .networkError(underlying) （带 1 次重试）
//   - URLSession timeout → .timeout
//   - 200 但 body 解析失败 / 缺 choices[0].message.content → .invalidResponse
//
// 设计决策：
//   - 协议层只暴露 prompt → text 单一能力（跟 Brain 既有 `complete(prompt:)` 对齐）
//     不暴露 system prompt / 多轮 chat（AGENTS.md 里 pet 用 single-prompt + Brain
//     拼 system+user 的拼装策略）
//   - temperature / max_tokens 走硬编码 default，**不**给 caller 配（spec 没要求）
//     以后要做"用户调温度"再加 property
//   - baseURL 走 `https://api.openai.com` default；OpenAICompatibleProvider 走同协议
//     换 baseURL
//   - URLSession 注入：init 接受 `session: URLSession` 让测试用 URLProtocol mock
//

import Foundation

// MARK: - OpenAIProvider

public final class OpenAIProvider: AsyncLLMProvider {

    public let name: String = "openai"
    public let model: String
    public let baseURL: URL

    private let apiKey: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let retryBaseDelay: TimeInterval

    /// 构造真 OpenAI provider。
    /// - Parameters:
    ///   - apiKey: OpenAI API key（`sk-...` 形式）
    ///   - model: 模型名（default `gpt-4o-mini`；想用 4o / 4-turbo 也行）
    ///   - baseURL: API root（default `https://api.openai.com`）
    ///   - session: 注入式 URLSession（测试用 URLProtocol mock；生产用 .shared）
    ///   - timeout: URLSession timeout（default 30s）
    ///   - maxRetries: network error 重试次数（default 1）
    ///   - retryBaseDelay: 重试基础 delay 秒数（default 0.5s；测试可调到 0 加速）
    public init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        baseURL: URL? = nil,
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        maxRetries: Int = 1,
        retryBaseDelay: TimeInterval = 0.5
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL ?? URL(string: "https://api.openai.com")!
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
        let url = baseURL.appendingPathComponent("/v1/chat/completions")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.7,
            "max_tokens": 500
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return req
    }

    // MARK: - HTTP 执行 + 重试

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
                // 4xx（除 timeout）→ 不重试
                switch err {
                case .unauthorized, .rateLimited, .serverError, .invalidResponse, .timeout:
                    throw err
                case .networkError:
                    lastError = err
                    attempt += 1
                    if attempt > maxRetries { throw err }
                    // 指数退避（只有 1 次重试时 = baseDelay；>=2 次时 = baseDelay * 2^(attempt-1)）
                    let delay = retryBaseDelay * pow(2.0, Double(attempt - 1))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            } catch {
                // 非 LLMError 的 transport 错（URLError）→ map 成 LLMError.networkError
                let mapped = LLMError.map(urlError: error)
                lastError = mapped
                attempt += 1
                if attempt > maxRetries { throw mapped }
                let delay = retryBaseDelay * pow(2.0, Double(attempt - 1))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError ?? LLMError.invalidResponse(reason: "OpenAI performWithRetry exhausted")
    }

    // MARK: - HTTP 状态码 → LLMError

    static func validate(httpResponse: HTTPURLResponse, data: Data) throws {
        switch httpResponse.statusCode {
        case 200..<300:
            return
        case 401:
            throw LLMError.unauthorized
        case 429:
            // 解析 retry-after header（秒数 / HTTP-date 都行；这里只取秒数）
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
            throw LLMError.invalidResponse(reason: "OpenAI response is not a JSON object")
        }
        guard let choices = obj["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw LLMError.invalidResponse(reason: "OpenAI response missing 'choices'")
        }
        guard let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.invalidResponse(reason: "OpenAI response missing choices[0].message.content")
        }
        return content
    }
}

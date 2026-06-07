// OpenAICompatibleProvider.swift
// 给用户自托管 endpoint（Ollama / LM Studio / vLLM / OpenRouter 等）用的 OpenAI 协议
//
// 协议：跟 OpenAIProvider 一样，POST {endpoint}/v1/chat/completions
//   Headers:
//     Authorization: Bearer <apiKey>  （**可选** — Ollama / LM Studio 本地服务可能不需要 key）
//     Content-Type: application/json
//   Body / Response：跟 OpenAI 一样
//
// 跟 OpenAIProvider 的关键差异：
//   - `name` = `"openai-compatible:<endpoint>"` （**唯一标识** 给 keychain account 用）
//   - `apiKey` 可选（Ollama 默认无 auth；LM Studio 也无；vLLM 可有可无）
//   - `endpoint` 必填（没有 default — caller 必须提供）
//   - 解析逻辑完全复用 OpenAI 的 JSON 形状（不重新实现 parseResponse）
//
// 设计决策：
//   - **不**继承 OpenAIProvider（避免 baseURL 字段冲突、timeout 重复构造）
//   - 单独实现 parseResponse（结构相同但 endpoint 不同，response body 是同一形态）
//   - keychain account 名 = `"openai-compatible:<endpoint>"`（**包括 scheme + host + port**；
//     不做 normalization — caller 自己保证 endpoint 字符串稳定）
//

import Foundation

// MARK: - OpenAICompatibleProvider

public final class OpenAICompatibleProvider: AsyncLLMProvider {

    public let name: String
    public let endpoint: URL
    public let model: String

    private let apiKey: String?
    private let session: URLSession
    private let timeout: TimeInterval
    private let maxRetries: Int
    private let retryBaseDelay: TimeInterval

    /// - Parameters:
    ///   - endpoint: API root（如 `http://localhost:11434` for Ollama）
    ///   - apiKey: 可选；Ollama / LM Studio 本地服务可能不需要
    ///   - model: 模型名（Ollama 跑 llama3 时填 `"llama3"`；vLLM 跑 qwen 时填 `"Qwen/Qwen2.5-7B-Instruct"`）
    ///   - session: 注入式 URLSession
    ///   - timeout: URLSession timeout（Ollama 本地可能响应慢；可调到 60s）
    ///   - maxRetries: network error 重试次数
    ///   - retryBaseDelay: 重试基础 delay
    public init(
        endpoint: URL,
        apiKey: String? = nil,
        model: String,
        session: URLSession = .shared,
        timeout: TimeInterval = 30,
        maxRetries: Int = 1,
        retryBaseDelay: TimeInterval = 0.5
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.timeout = timeout
        self.maxRetries = maxRetries
        self.retryBaseDelay = retryBaseDelay
        // name 用 endpoint 字符串的 absoluteString（"http://localhost:11434"）作唯一标识
        self.name = "openai-compatible:\(endpoint.absoluteString)"
    }

    // MARK: - AsyncLLMProvider

    public func complete(prompt: String) async throws -> String {
        let request = try buildRequest(prompt: prompt)
        let data = try await performWithRetry(request: request)
        return try parseResponse(data: data)
    }

    // MARK: - request 构造（internal 暴露给 test）

    func buildRequest(prompt: String) throws -> URLRequest {
        let url = endpoint.appendingPathComponent("/v1/chat/completions")
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = "POST"
        if let key = apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
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

    // MARK: - HTTP 执行 + 重试（同 OpenAI）

    private func performWithRetry(request: URLRequest) async throws -> Data {
        var attempt = 0
        var lastError: Error?

        while attempt <= maxRetries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw LLMError.invalidResponse(reason: "response is not HTTPURLResponse")
                }
                try OpenAIProvider.validate(httpResponse: http, data: data)
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
        throw lastError ?? LLMError.invalidResponse(reason: "OpenAICompatible performWithRetry exhausted")
    }

    // MARK: - 响应解析（同 OpenAI 协议）

    func parseResponse(data: Data) throws -> String {
        // 复用 OpenAIProvider 的解析（chat completions 协议相同）
        // 直接 inline 写一遍而不是 delegate 到 OpenAIProvider 的 static 方法，
        // 是因为 parseResponse 在 OpenAIProvider 是 instance method。
        // 静态 helper 暴露需要改 OpenAIProvider — 避免改动。
        // 形态相同（choices[0].message.content），所以这里照写。
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.invalidResponse(reason: "OpenAI-compatible response is not a JSON object")
        }
        guard let choices = obj["choices"] as? [[String: Any]], !choices.isEmpty else {
            throw LLMError.invalidResponse(reason: "OpenAI-compatible response missing 'choices'")
        }
        guard let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw LLMError.invalidResponse(reason: "OpenAI-compatible response missing choices[0].message.content")
        }
        return content
    }
}

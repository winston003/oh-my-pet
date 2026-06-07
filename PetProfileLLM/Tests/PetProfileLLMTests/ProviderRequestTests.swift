// ProviderRequestTests.swift
// 3 个真 provider 的 HTTP request 构造测试
//
// 覆盖（per spec）：
//   - OpenAIProvider：URL / headers / body JSON 形状 / temperature / max_tokens
//   - ClaudeProvider：URL / headers (x-api-key + anthropic-version) / body JSON 形状
//   - OpenAICompatibleProvider：endpoint 自定义 / apiKey 可选 / headers
//
// 测试策略：
//   - 用 URLProtocolMock 拦截 URLSession.dataTask
//   - 验证 capturedRequests[0] 的 URL / method / headers / body
//   - 不发真请求
//
// 越界检查：
//   - 不写真 API key（用 "test-key" fixture 字符串）
//   - 不调真 endpoint
//   - URLProtocolMock.register / unregister 必须成对（每个 test 调 defer unregister）
//

import Foundation
@testable import PetProfileLLM

func registerProviderRequestTests(_ tests: Tests) {

    // MARK: - OpenAIProvider

    tests.add("OpenAIProvider.testRequest_urlMethodHeaders") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAIProvider(
            apiKey: "sk-test-1234567890",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        try XCTAssertEqual(mock.capturedRequests.count, 1)
        let req = mock.capturedRequests[0]
        try XCTAssertEqual(req.httpMethod, "POST")
        try XCTAssertEqual(req.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-1234567890")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    tests.add("OpenAIProvider.testRequest_bodyShape") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", model: "gpt-4o", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "Hello, world")
        }

        let req = mock.capturedRequests[0]
        guard let bodyData = req.httpBody else {
            throw TestFailure(name: "OpenAIProvider.testRequest_bodyShape", message: "missing httpBody")
        }
        let body = try XCTUnwrap(
            (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
            "body is not a JSON object"
        )
        try XCTAssertEqual(body["model"] as? String, "gpt-4o")
        try XCTAssertEqual(body["temperature"] as? Double, 0.7)
        try XCTAssertEqual(body["max_tokens"] as? Int, 500)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        try XCTAssertEqual(messages.count, 1)
        try XCTAssertEqual(messages[0]["role"] as? String, "user")
        try XCTAssertEqual(messages[0]["content"] as? String, "Hello, world")
    }

    tests.add("OpenAIProvider.testRequest_customBaseURL") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAIProvider(
            apiKey: "sk-test",
            baseURL: URL(string: "https://custom.openai.example.com"),
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        let req = mock.capturedRequests[0]
        try XCTAssertEqual(req.url?.absoluteString, "https://custom.openai.example.com/v1/chat/completions")
    }

    // MARK: - ClaudeProvider

    tests.add("ClaudeProvider.testRequest_urlMethodHeaders") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["content": [["type": "text", "text": "ok"]]]))
        let session = mock.makeSession()
        let provider = ClaudeProvider(
            apiKey: "sk-ant-test-1234567890",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        try XCTAssertEqual(mock.capturedRequests.count, 1)
        let req = mock.capturedRequests[0]
        try XCTAssertEqual(req.httpMethod, "POST")
        try XCTAssertEqual(req.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test-1234567890")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    tests.add("ClaudeProvider.testRequest_bodyShape") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["content": [["type": "text", "text": "ok"]]]))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", model: "claude-3-5-sonnet-20241022", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "Hello, Claude")
        }

        let req = mock.capturedRequests[0]
        let body = try XCTUnwrap(
            ((try? JSONSerialization.jsonObject(with: req.httpBody ?? Data())) as? [String: Any]),
            "body is not a JSON object"
        )
        try XCTAssertEqual(body["model"] as? String, "claude-3-5-sonnet-20241022")
        try XCTAssertEqual(body["max_tokens"] as? Int, 500)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        try XCTAssertEqual(messages.count, 1)
        try XCTAssertEqual(messages[0]["role"] as? String, "user")
        try XCTAssertEqual(messages[0]["content"] as? String, "Hello, Claude")
        // Claude 不接受 temperature 字段在 spec 范围（spec body 模板里没列）
        try XCTAssertNil(body["temperature"], "Claude spec body 不应包含 temperature")
    }

    tests.add("ClaudeProvider.testRequest_customBaseURLAndVersion") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["content": [["type": "text", "text": "ok"]]]))
        let session = mock.makeSession()
        let provider = ClaudeProvider(
            apiKey: "sk-ant-test",
            baseURL: URL(string: "https://custom.anthropic.example.com"),
            apiVersion: "2024-01-01",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        let req = mock.capturedRequests[0]
        try XCTAssertEqual(req.url?.absoluteString, "https://custom.anthropic.example.com/v1/messages")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-version"), "2024-01-01")
    }

    // MARK: - OpenAICompatibleProvider

    tests.add("OpenAICompatibleProvider.testRequest_localEndpoint") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        let req = mock.capturedRequests[0]
        try XCTAssertEqual(req.httpMethod, "POST")
        try XCTAssertEqual(req.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        try XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    tests.add("OpenAICompatibleProvider.testRequest_noApiKey_omitsAuthHeader") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://localhost:11434")!,
            apiKey: nil,  // Ollama 本地
            model: "llama3",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        let req = mock.capturedRequests[0]
        try XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "no key → no auth header")
    }

    tests.add("OpenAICompatibleProvider.testRequest_withApiKey_addsBearer") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "https://vllm.example.com")!,
            apiKey: "test-key",
            model: "Qwen/Qwen2.5-7B-Instruct",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            _ = try await provider.complete(prompt: "hi")
        }

        let req = mock.capturedRequests[0]
        try XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
    }

    tests.add("OpenAICompatibleProvider.testName_usesEndpoint") { _ in
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3"
        )
        try XCTAssertEqual(provider.name, "openai-compatible:http://localhost:11434")
    }

    // MARK: - OpenAI / Claude name 字段

    tests.add("OpenAIProvider.testName_isOpenAI") { _ in
        let provider = OpenAIProvider(apiKey: "sk-test")
        try XCTAssertEqual(provider.name, "openai")
    }

    tests.add("ClaudeProvider.testName_isClaude") { _ in
        let provider = ClaudeProvider(apiKey: "sk-ant-test")
        try XCTAssertEqual(provider.name, "claude")
    }
}

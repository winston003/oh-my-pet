// ProviderResponseTests.swift
// 3 个真 provider 的 response 解析测试
//
// 覆盖（per spec）：
//   - 成功：3 provider 各自从成功 body 抽出 text
//   - 错误（4 类）：
//     - 401 → .unauthorized
//     - 429 → .rateLimited(retry-after header)
//     - 5xx → .serverError(statusCode)
//     - 200 但 body 损坏 / 缺字段 → .invalidResponse
//
// 越界检查：
//   - 不调真 API
//   - URLProtocolMock 拦截 + canned response
//

import Foundation
@testable import PetProfileLLM

func registerProviderResponseTests(_ tests: Tests) {

    // MARK: - OpenAI 成功路径

    tests.add("OpenAIProvider.testResponse_success") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        let body: [String: Any] = [
            "choices": [
                ["message": ["content": "你好，胖可！"]]
            ]
        ]
        mock.setResponse(.json(body))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "你好，胖可！")
        }
    }

    tests.add("OpenAIProvider.testResponse_multipleChoices_picksFirst") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        let body: [String: Any] = [
            "choices": [
                ["message": ["content": "first"]],
                ["message": ["content": "second"]]
            ]
        ]
        mock.setResponse(.json(body))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "first")
        }
    }

    // MARK: - OpenAI 错误路径

    tests.add("OpenAIProvider.testResponse_401_throwsUnauthorized") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "invalid api key"], statusCode: 401))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-bad", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "openai-401", message: "expected throw")
            } catch let err as LLMError {
                if case .unauthorized = err { return }
                throw err
            }
        }
    }

    tests.add("OpenAIProvider.testResponse_429_withRetryAfter") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(
            ["error": "rate limit"],
            statusCode: 429,
            extraHeaders: ["Retry-After": "12"]
        ))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "openai-429", message: "expected throw")
            } catch let err as LLMError {
                if case .rateLimited(let retry) = err {
                    try XCTAssertEqualD(retry ?? -1, 12, accuracy: 0.01)
                    return
                }
                throw err
            }
        }
    }

    tests.add("OpenAIProvider.testResponse_5xx_throwsServerError") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "internal"], statusCode: 503))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "openai-503", message: "expected throw")
            } catch let err as LLMError {
                if case .serverError(let code) = err {
                    try XCTAssertEqual(code, 503)
                    return
                }
                throw err
            }
        }
    }

    tests.add("OpenAIProvider.testResponse_200ButMissingChoices_throwsInvalidResponse") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "missing choices"]))  // 200 但 body 不对
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "openai-invalid", message: "expected throw")
            } catch let err as LLMError {
                if case .invalidResponse = err { return }
                throw err
            }
        }
    }

    tests.add("OpenAIProvider.testResponse_garbageJSON_throwsInvalidResponse") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        // 200 + 非 JSON body
        let resp = URLProtocolMock.MockResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data("not json at all".utf8)
        )
        mock.setResponse(resp)
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "openai-garbage", message: "expected throw")
            } catch let err as LLMError {
                if case .invalidResponse = err { return }
                throw err
            }
        }
    }

    // MARK: - Claude 成功路径

    tests.add("ClaudeProvider.testResponse_success") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        let body: [String: Any] = [
            "content": [
                ["type": "text", "text": "你好，胖可！"]
            ]
        ]
        mock.setResponse(.json(body))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "你好，胖可！")
        }
    }

    tests.add("ClaudeProvider.testResponse_multipleTextBlocks_joinsWithNewline") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        let body: [String: Any] = [
            "content": [
                ["type": "text", "text": "第一段"],
                ["type": "text", "text": "第二段"]
            ]
        ]
        mock.setResponse(.json(body))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "第一段\n第二段")
        }
    }

    tests.add("ClaudeProvider.testResponse_ignoresNonTextBlocks") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        let body: [String: Any] = [
            "content": [
                ["type": "tool_use", "id": "x"],  // 非 text block
                ["type": "text", "text": "only text"]
            ]
        ]
        mock.setResponse(.json(body))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "only text")
        }
    }

    // MARK: - Claude 错误路径

    tests.add("ClaudeProvider.testResponse_401_throwsUnauthorized") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "unauthorized"], statusCode: 401))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-bad", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "claude-401", message: "expected throw")
            } catch let err as LLMError {
                if case .unauthorized = err { return }
                throw err
            }
        }
    }

    tests.add("ClaudeProvider.testResponse_429_withRetryAfter") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(
            ["error": "rate limit"],
            statusCode: 429,
            extraHeaders: ["Retry-After": "30"]
        ))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "claude-429", message: "expected throw")
            } catch let err as LLMError {
                if case .rateLimited(let retry) = err {
                    try XCTAssertEqualD(retry ?? -1, 30, accuracy: 0.01)
                    return
                }
                throw err
            }
        }
    }

    tests.add("ClaudeProvider.testResponse_5xx_throwsServerError") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "internal"], statusCode: 500))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "claude-500", message: "expected throw")
            } catch let err as LLMError {
                if case .serverError(let code) = err {
                    try XCTAssertEqual(code, 500)
                    return
                }
                throw err
            }
        }
    }

    tests.add("ClaudeProvider.testResponse_200ButMissingContent_throwsInvalidResponse") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "no content"]))  // 200 但缺 content
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "claude-invalid", message: "expected throw")
            } catch let err as LLMError {
                if case .invalidResponse = err { return }
                throw err
            }
        }
    }

    // MARK: - OpenAICompatible 成功 / 错误

    tests.add("OpenAICompatibleProvider.testResponse_success") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        let body: [String: Any] = [
            "choices": [
                ["message": ["content": "llama3 says hi"]]
            ]
        ]
        mock.setResponse(.json(body))
        let session = mock.makeSession()
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "llama3 says hi")
        }
    }

    tests.add("OpenAICompatibleProvider.testResponse_5xx_throwsServerError") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "vllm down"], statusCode: 503))
        let session = mock.makeSession()
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://localhost:8000")!,
            model: "qwen",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "compat-503", message: "expected throw")
            } catch let err as LLMError {
                if case .serverError(let code) = err {
                    try XCTAssertEqual(code, 503)
                    return
                }
                throw err
            }
        }
    }
}

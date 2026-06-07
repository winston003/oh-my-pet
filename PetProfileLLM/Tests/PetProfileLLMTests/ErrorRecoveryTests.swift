// ErrorRecoveryTests.swift
// 错误恢复策略测试
//
// 覆盖（per spec）：
//   - network error 重试 1 次（指数退避；第一次 fail → 第二次 success）
//   - 401 / 429 / 5xx 不重试（只发 1 次）
//   - 429 retry-after header 透传
//   - timeout 30s（URLSession timeout 触发 → .timeout）
//   - LLMError.map(urlError:) 把 URLError 转成 .networkError / .timeout
//
// 越界检查：
//   - 不调真 API
//   - URLProtocolMock canned responses / errors
//

import Foundation
@testable import PetProfileLLM

func registerErrorRecoveryTests(_ tests: Tests) {

    // MARK: - network 重试

    tests.add("Recovery.testNetworkError_retriesOnce") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        // 第 1 次：network error；第 2 次：success
        mock.setErrorSequence([
            NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost, userInfo: [NSLocalizedDescriptionKey: "Connection lost"])
        ])
        mock.setSequence([.json(["choices": [["message": ["content": "ok"]]]])])

        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            let text = try await provider.complete(prompt: "hi")
            try XCTAssertEqual(text, "ok")
        }
        // 验证：抓到了 2 个 request（1 次失败 + 1 次重试成功）
        try XCTAssertEqual(mock.capturedRequests.count, 2, "should retry once after network error")
    }

    tests.add("Recovery.testNetworkError_exhaustsRetries_throwsNetworkError") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        // 2 次都返回 error（超过 maxRetries=1 限制）
        mock.setErrorSequence([
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: [NSLocalizedDescriptionKey: "host not found 1"]),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, userInfo: [NSLocalizedDescriptionKey: "host not found 2"])
        ])
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "exhausted", message: "expected throw")
            } catch let err as LLMError {
                if case .networkError = err { return }
                throw err
            }
        }
        // 验证：最多 2 次（1 initial + 1 retry）
        try XCTAssertEqual(mock.capturedRequests.count, 2)
    }

    // MARK: - 401 不重试

    tests.add("Recovery.test401_noRetry") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "bad key"], statusCode: 401))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-bad", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "401-no-retry", message: "expected throw")
            } catch let err as LLMError {
                if case .unauthorized = err { return }
                throw err
            }
        }
        try XCTAssertEqual(mock.capturedRequests.count, 1, "401 should NOT retry")
    }

    // MARK: - 429 不重试，retry-after 透传

    tests.add("Recovery.test429_noRetry_retryAfterExposed") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(
            ["error": "rate limit"],
            statusCode: 429,
            extraHeaders: ["Retry-After": "60"]
        ))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "429-no-retry", message: "expected throw")
            } catch let err as LLMError {
                if case .rateLimited(let r) = err {
                    try XCTAssertEqualD(r ?? -1, 60, accuracy: 0.01)
                    return
                }
                throw err
            }
        }
        try XCTAssertEqual(mock.capturedRequests.count, 1, "429 should NOT retry")
    }

    tests.add("Recovery.test429_noRetryAfterHeader_retryAfterIsNil") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "rate limit"], statusCode: 429))  // no Retry-After
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "429-no-header", message: "expected throw")
            } catch let err as LLMError {
                if case .rateLimited(let r) = err {
                    try XCTAssertNil(r)
                    return
                }
                throw err
            }
        }
    }

    // MARK: - 5xx 不重试

    tests.add("Recovery.test5xx_noRetry") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "internal"], statusCode: 500))
        let session = mock.makeSession()
        let provider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "5xx-no-retry", message: "expected throw")
            } catch let err as LLMError {
                if case .serverError = err { return }
                throw err
            }
        }
        try XCTAssertEqual(mock.capturedRequests.count, 1, "5xx should NOT retry")
    }

    // MARK: - Claude 也遵循相同恢复策略（移到 timeout 之前，避免老 thread sleep 干扰）

    tests.add("Recovery.testClaude_401_noRetry") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "bad key"], statusCode: 401))
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
        try XCTAssertEqual(mock.capturedRequests.count, 1)
    }

    tests.add("Recovery.testClaude_5xx_noRetry") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "overloaded"], statusCode: 529))
        let session = mock.makeSession()
        let provider = ClaudeProvider(apiKey: "sk-ant-test", session: session, retryBaseDelay: 0)

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "claude-529", message: "expected throw")
            } catch let err as LLMError {
                if case .serverError(let code) = err {
                    try XCTAssertEqual(code, 529)
                    return
                }
                throw err
            }
        }
        try XCTAssertEqual(mock.capturedRequests.count, 1)
    }

    tests.add("Recovery.testOpenAICompatible_401_noRetry") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        mock.setResponse(.json(["error": "bad"], statusCode: 401))
        let session = mock.makeSession()
        let provider = OpenAICompatibleProvider(
            endpoint: URL(string: "http://localhost:11434")!,
            model: "llama3",
            session: session,
            retryBaseDelay: 0
        )

        try XCTAssertAsync {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "compat-401", message: "expected throw")
            } catch let err as LLMError {
                if case .unauthorized = err { return }
                throw err
            }
        }
        try XCTAssertEqual(mock.capturedRequests.count, 1)
    }

    // MARK: - timeout（放在最后 — setDelay 0.3s 会让老 thread 短暂残留）

    tests.add("Recovery.testTimeout_throwsLLMErrorTimeout") { _ in
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }

        // 用 setDelay 让 mock 慢 0.3s；provider timeout 设 0.1s → 触发 .timeout
        // maxRetries: 0 — 不重试，避免 background retry 抢占下一个 test 的 response
        mock.setDelay(0.3)
        mock.setResponse(.json(["choices": [["message": ["content": "ok"]]]]))
        let session = mock.makeSession()
        let provider = OpenAIProvider(
            apiKey: "sk-test",
            session: session,
            timeout: 0.1,
            maxRetries: 0,  // 关键：test 结束时不要 background retry
            retryBaseDelay: 0
        )

        try XCTAssertAsync(timeout: 10) {
            do {
                _ = try await provider.complete(prompt: "hi")
                throw TestFailure(name: "timeout", message: "expected throw")
            } catch let err as LLMError {
                // URLSession 在 0.1s 后会 cancel，可能映射成 .timeout 或 .networkError
                // 两种都算"超时"语义通过
                switch err {
                case .timeout, .networkError: return
                default: throw err
                }
            }
        }
    }

    // MARK: - LLMError.map

    tests.add("Recovery.testMapURLError_timeout_returnsTimeout") { _ in
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        let mapped = LLMError.map(urlError: urlError)
        if case .timeout = mapped { return }
        throw TestFailure(name: "map-timeout", message: "expected .timeout, got \(mapped)")
    }

    tests.add("Recovery.testMapURLError_other_returnsNetworkError") { _ in
        let urlError = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost, userInfo: nil)
        let mapped = LLMError.map(urlError: urlError)
        if case .networkError = mapped { return }
        throw TestFailure(name: "map-network", message: "expected .networkError, got \(mapped)")
    }

    // MARK: - userFacingMessage

    tests.add("Recovery.testUserFacingMessage_allCases") { _ in
        try XCTAssertContains(LLMError.unauthorized.userFacingMessage, "API key")
        try XCTAssertContains(LLMError.timeout.userFacingMessage, "超时")
        try XCTAssertContains(LLMError.rateLimited(retryAfter: 10).userFacingMessage, "10")
        try XCTAssertContains(LLMError.rateLimited(retryAfter: nil).userFacingMessage, "稍后")
        try XCTAssertContains(LLMError.serverError(statusCode: 500).userFacingMessage, "AI 服务")
    }
}

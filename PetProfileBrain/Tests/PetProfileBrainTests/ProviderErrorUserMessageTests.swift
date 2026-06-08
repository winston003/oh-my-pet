// ProviderErrorUserMessageTests.swift
// ProviderError.userMessage 5-case friendly 文本断言
//
// 对应 spec §3.1 P4 诚实感知：
//   - keyMissing      → "🔑 Provider requires an API key. Configure it in Settings."
//   - rateLimited     → "Provider is rate-limited. Please try again in a few seconds."
//   - contentRefused  → "Provider refused this content (likely safety filter)."
//   - notImplemented  → "This provider is not yet wired. Switch to Stub in the dropdown."
//   - 其他            → "Provider error: {kind}"
//
// 覆盖：
//   - 5 case 各自 userMessage 内容
//   - 全部 case 都**不**含 "ProviderError:" debug 前缀
//   - 全部 case 都不直接暴露 reason（spec P3 隐私）
//   - Equatable + 自描述 description
//   - ProviderError 的 rateLimited case 真存在（P2-L-3 新增）
//
// 不做：
//   - 不测 UI 层 SelectionCoordinator.friendlyMessage（属 PetProfileStudio）
//   - 不测跨 layer 串扰
//

import Foundation
@testable import PetProfileBrain

func registerProviderErrorUserMessageTests(_ tests: Tests) {

    // MARK: - 5 个 spec 标准的文案 case

    tests.add("ProviderErrorUserMessage.testKeyMissing") { _ in
        let msg = ProviderError.keyMissing(providerID: "openai-gpt").userMessage
        try XCTAssertTrue(msg.contains("🔑"), "expected 🔑 emoji in \(msg)")
        try XCTAssertContains(msg, "API key")
        try XCTAssertContains(msg, "Settings")
    }

    tests.add("ProviderErrorUserMessage.testRateLimited") { _ in
        let msg = ProviderError.rateLimited(reason: "429 too many requests").userMessage
        try XCTAssertTrue(msg.lowercased().contains("rate"), "expected 'rate' in \(msg)")
        try XCTAssertTrue(msg.lowercased().contains("try again"), "expected retry hint in \(msg)")
    }

    tests.add("ProviderErrorUserMessage.testContentRefused") { _ in
        let msg = ProviderError.contentRefused(reason: "safety filter triggered").userMessage
        try XCTAssertTrue(msg.lowercased().contains("refus"), "expected 'refused' in \(msg)")
        try XCTAssertTrue(msg.lowercased().contains("safety") || msg.lowercased().contains("filter"),
            "expected safety/filter hint in \(msg)")
    }

    tests.add("ProviderErrorUserMessage.testNotImplemented") { _ in
        let msg = ProviderError.notImplemented(providerID: "openai-gpt", message: "wip").userMessage
        try XCTAssertContains(msg, "not yet wired")
        try XCTAssertContains(msg, "Switch to Stub")
    }

    tests.add("ProviderErrorUserMessage.testNetworkError") { _ in
        let msg = ProviderError.networkError(reason: "DNS fail").userMessage
        try XCTAssertTrue(msg.lowercased().contains("network"), "expected 'network' in \(msg)")
        try XCTAssertTrue(msg.lowercased().contains("error") || msg.lowercased().contains("provider"),
            "expected error/provider context in \(msg)")
    }

    tests.add("ProviderErrorUserMessage.testUnknown") { _ in
        let msg = ProviderError.unknown(reason: "weird state").userMessage
        try XCTAssertTrue(msg.lowercased().contains("error"), "expected 'error' in \(msg)")
    }

    // MARK: - 隐私 / debug 前缀

    tests.add("ProviderErrorUserMessage.testNoDebugPrefix") { _ in
        // userMessage **不**应含 "ProviderError:" debug 前缀
        let errors: [ProviderError] = [
            .keyMissing(providerID: "x"),
            .rateLimited(reason: "x"),
            .contentRefused(reason: "x"),
            .notImplemented(providerID: "x", message: "x"),
            .networkError(reason: "x"),
            .unknown(reason: "x"),
            .providerNotFound(id: "x"),
        ]
        for e in errors {
            try XCTAssertFalse(e.userMessage.contains("ProviderError:"),
                "userMessage should NOT contain 'ProviderError:' prefix; got: \(e.userMessage)")
        }
    }

    tests.add("ProviderErrorUserMessage.testDoesNotLeakReason") { _ in
        // userMessage **不**直接暴露 reason（spec P3 隐私）
        let sensitiveReasons: [(ProviderError, String)] = [
            (.rateLimited(reason: "SECRET_TOKEN_xyz"), "SECRET_TOKEN"),
            (.contentRefused(reason: "API returned status 418 with body INTERNAL_DETAIL"), "INTERNAL_DETAIL"),
            (.networkError(reason: "fail with secret XYZ123ABC"), "XYZ123ABC"),
            (.unknown(reason: "weird secret ABC12345"), "ABC12345"),
        ]
        for (e, sensitive) in sensitiveReasons {
            try XCTAssertFalse(e.userMessage.contains(sensitive),
                "userMessage must not leak reason '\(sensitive)'; got: \(e.userMessage)")
        }
    }

    // MARK: - description / debug 行为

    tests.add("ProviderErrorUserMessage.testDescriptionContainsDebugInfo") { _ in
        // description 仍含完整 debug info（**不**是 userMessage）
        let e = ProviderError.rateLimited(reason: "test 429")
        let desc = e.description
        try XCTAssertContains(desc, "rate limited")
        try XCTAssertContains(desc, "test 429")
    }

    // MARK: - Equatable

    tests.add("ProviderErrorUserMessage.testEquatable") { _ in
        let a = ProviderError.rateLimited(reason: "x")
        let b = ProviderError.rateLimited(reason: "x")
        let c = ProviderError.rateLimited(reason: "y")
        try XCTAssertEqual(a, b)
        try XCTAssertNotEqual(a, c)
    }
}

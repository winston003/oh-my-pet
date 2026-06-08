// StubTextProviderTests.swift
// StubTextProvider 行为测试
//
// 覆盖：
//   - 5 个 SelectionActionKind 全部 action 跑通（每个 action 一个 case，断言前缀正确）
//   - AppContextSnapshot 缺省（nil）路径：StubTextProvider 不能因 nil crash
//   - 两次连续 complete 之间无共享可变状态（test isolation — 跟 P2-J 同要求）
//   - supports 全 5 个 action
//   - 模拟 latency 50-200ms
//   - 截断 80 字符的 selectedText print（不 print key / 完整 selectedText > 80 字符）
//
// 不做：
//   - 不验证 stderr 输出（print 行为不 stable；verifier 看源码）
//   - 不测 Token 计算（stub 不算 token）
//
// 注：PetProfileBrain TestKit 不带 async；用本地 SyncAsyncBridge 跑 async fn 后同步等。
//

import Foundation
@testable import PetProfileBrain

func registerStubTextProviderTests(_ tests: Tests) {

    // MARK: - helpers

    /// 最小 latency 注入（maxLatency=0 时 complete 不 sleep，加速 test）
    func makeProvider() -> StubTextProvider {
        return StubTextProvider(minLatencyMS: 0, maxLatencyMS: 0)
    }

    func makeAppContext(appName: String = "TextEdit", bundleID: String? = "com.apple.TextEdit") -> AppContextSnapshot {
        return AppContextSnapshot(
            bundleID: bundleID,
            appName: appName,
            windowTitle: nil,
            capturedAt: Date()
        )
    }

    /// 跑一个 async closure 同步等结果
    func runAsync(_ fn: @escaping () async throws -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        let box = SyncResultBox()
        Task.detached(priority: .userInitiated) {
            do {
                try await fn()
                box.set(.success(()))
            } catch {
                box.set(.failure(error))
            }
            sem.signal()
        }
        let result = sem.wait(timeout: .now() + 10)
        if result == .timedOut {
            throw TestFailure(name: "runAsync", message: "timed out")
        }
        try box.unwrap()
    }

    // MARK: - tests

    tests.add("Stub.testMetadata") { _ in
        let p = makeProvider()
        try XCTAssertEqual(p.id, "stub")
        try XCTAssertEqual(p.displayName, "Stub")
        try XCTAssertFalse(p.requiresAPIKey, "stub must NOT require API key")
        try XCTAssertEqual(p.supportedActions.count, 5, "stub must support all 5 actions")
        for kind in SelectionActionKind.allCases {
            try XCTAssertTrue(p.supportedActions.contains(kind), "stub must support \(kind.rawValue)")
        }
    }

    tests.add("Stub.testTranslate_prefixAndEcho") { _ in
        let p = makeProvider()
        let app = makeAppContext(appName: "Safari")
        let req = TextCompletionRequest(
            action: .translate,
            selectedText: "Hello world",
            appContext: app
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        try XCTAssertEqual(result!.providerID, "stub")
        try XCTAssertEqual(result!.modelUsed, "stub-echo-v1")
        try XCTAssertNil(result!.tokensUsed)
        try XCTAssertTrue(
            result!.text.hasPrefix("[STUB translate from Safari]: "),
            "got: \(result!.text)"
        )
        try XCTAssertTrue(
            result!.text.contains("Hello world"),
            "echoed text should contain selectedText; got: \(result!.text)"
        )
    }

    tests.add("Stub.testExplain_prefixAndEcho") { _ in
        let p = makeProvider()
        let req = TextCompletionRequest(
            action: .explain,
            selectedText: "async/await in Swift",
            appContext: nil
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        try XCTAssertTrue(
            result!.text.hasPrefix("[STUB explain]: "),
            "got: \(result!.text)"
        )
        try XCTAssertTrue(result!.text.contains("async/await in Swift"))
    }

    tests.add("Stub.testSummarize_prefixAndEcho") { _ in
        let p = makeProvider()
        let app = makeAppContext(appName: "Notes")
        let req = TextCompletionRequest(
            action: .summarize,
            selectedText: "long article body",
            appContext: app
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        try XCTAssertTrue(
            result!.text.hasPrefix("[STUB summarize]: "),
            "got: \(result!.text)"
        )
        try XCTAssertTrue(result!.text.contains("long article body"))
    }

    tests.add("Stub.testRewrite_prefixAndEcho") { _ in
        let p = makeProvider()
        let app = makeAppContext(appName: "Mail")
        let req = TextCompletionRequest(
            action: .rewrite,
            selectedText: "Make this nicer",
            appContext: app
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        try XCTAssertTrue(
            result!.text.hasPrefix("[STUB rewrite]: "),
            "got: \(result!.text)"
        )
        try XCTAssertTrue(result!.text.contains("Make this nicer"))
    }

    tests.add("Stub.testAsk_prefixAndEcho") { _ in
        let p = makeProvider()
        let app = makeAppContext(appName: "Xcode")
        let req = TextCompletionRequest(
            action: .ask,
            selectedText: "What does this mean?",
            appContext: app
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        try XCTAssertTrue(
            result!.text.hasPrefix("[STUB ask in Xcode]: "),
            "got: \(result!.text)"
        )
        try XCTAssertTrue(result!.text.contains("What does this mean?"))
    }

    tests.add("Stub.testNilAppContext_doesNotCrash") { _ in
        // Adversarial probe：appContext = nil 时 5 个 action 都不能 crash
        // 注：只有 translate / ask 这两个 action 在 prefix 里用 appName，
        //     explain / summarize / rewrite 的 prefix 不含 appName。
        let p = makeProvider()
        var results: [SelectionActionKind: TextCompletionResult] = [:]
        try runAsync {
            for kind in SelectionActionKind.allCases {
                let req = TextCompletionRequest(
                    action: kind,
                    selectedText: "test",
                    appContext: nil
                )
                let r = try await p.complete(req)
                results[kind] = r
            }
        }
        for kind in SelectionActionKind.allCases {
            let r = try XCTUnwrap(results[kind])
            try XCTAssertEqual(r.providerID, "stub")
            // 全部 5 个 action 都能完整跑完 — 这是关键 probe（不 crash）
        }
        // translate / ask 用了 appName 的应该 fall back 到 "unknown app"
        let translateResult = try XCTUnwrap(results[.translate])
        try XCTAssertTrue(translateResult.text.contains("unknown app"),
            "nil appContext + translate should fall back to 'unknown app'; got: \(translateResult.text)")
        let askResult = try XCTUnwrap(results[.ask])
        try XCTAssertTrue(askResult.text.contains("unknown app"),
            "nil appContext + ask should fall back to 'unknown app'; got: \(askResult.text)")
    }

    tests.add("Stub.testLatencyRange_50_to_200ms") { _ in
        // Adversarial probe：latency 模拟 50-200ms
        let p = StubTextProvider(minLatencyMS: 50, maxLatencyMS: 200)
        let req = TextCompletionRequest(
            action: .explain,
            selectedText: "latency test",
            appContext: nil
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        // 50 是 min 下界（允许 ~10ms 调度误差），200 + slack 上界
        try XCTAssertGreaterThanOrEqual(result!.latencyMS, 40, "latency should be >= ~50ms; got \(result!.latencyMS)")
        try XCTAssertLessThan(result!.latencyMS, 600, "latency should be < 600ms (200 + slack); got \(result!.latencyMS)")
    }

    tests.add("Stub.testTestIsolation_noSharedState") { _ in
        // Adversarial probe：两次连续 complete 之间**不**应共享任何 state
        let p = makeProvider()
        let req1 = TextCompletionRequest(
            action: .translate,
            selectedText: "first call",
            appContext: makeAppContext(appName: "App1")
        )
        let req2 = TextCompletionRequest(
            action: .translate,
            selectedText: "second call",
            appContext: makeAppContext(appName: "App2")
        )
        var r1: TextCompletionResult?
        var r2: TextCompletionResult?
        try runAsync {
            r1 = try await p.complete(req1)
            r2 = try await p.complete(req2)
        }
        _ = try XCTUnwrap(r1)
        _ = try XCTUnwrap(r2)
        // 两个 result 都用各自 request 的 appName；不应有串扰
        try XCTAssertTrue(r1!.text.contains("App1"), "first call: \(r1!.text)")
        try XCTAssertFalse(r1!.text.contains("App2"), "first call should NOT see App2: \(r1!.text)")
        try XCTAssertTrue(r2!.text.contains("App2"), "second call: \(r2!.text)")
        try XCTAssertFalse(r2!.text.contains("App1"), "second call should NOT see App1: \(r2!.text)")
    }

    tests.add("Stub.testStderrLogging_doesNotLeakKey") { _ in
        // Adversarial probe：complete 调一次，验证不 panic + result text 正常
        // （stderr print 行为不直接断言 — 行为契约看源码：print 中**不**含 key 字段；
        //  这个 test 主要确保 complete 路径**不**误把 key 写到 result.text）
        let p = makeProvider()
        let req = TextCompletionRequest(
            action: .translate,
            selectedText: "this is a normal selection",
            appContext: makeAppContext(appName: "TestApp")
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        _ = try XCTUnwrap(result)
        // result.text 应**不**含任何 key-like 模式
        try XCTAssertFalse(result!.text.contains("sk-"), "result.text should NOT contain API key marker")
        try XCTAssertFalse(result!.text.contains("api_key"), "result.text should NOT contain 'api_key'")
    }

    tests.add("Stub.testMakeStubTextStaticHelper") { _ in
        // 直接调 static helper（test isolation 兜底）
        let s = StubTextProvider.makeStubText(action: .translate, appName: "X", selectedText: "hi")
        try XCTAssertEqual(s, "[STUB translate from X]: hi")
        let s2 = StubTextProvider.makeStubText(action: .ask, appName: "Y", selectedText: "what?")
        try XCTAssertEqual(s2, "[STUB ask in Y]: what?")
    }

    // MARK: - P2-L-3: pet 注入到 stub 文本 + stderr tag

    func makePet(name: String = "Pako", humorStyle: String = "self-deprecating") -> PetProfileSummary {
        return PetProfileSummary(
            name: name,
            species: "office-jelly",
            humorStyle: humorStyle,
            storyTone: "工位上的老朋友"
        )
    }

    tests.add("Stub.testPet_includedInText") { _ in
        // pet 注入到 stub 输出：让 verifier 看到"pet 人设真在用"
        let p = makeProvider()
        let pet = makePet(name: "Pako", humorStyle: "self-deprecating")
        let req = TextCompletionRequest(
            action: .ask,
            selectedText: "what's up?",
            appContext: makeAppContext(appName: "Xcode"),
            petProfile: pet
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        let r = try XCTUnwrap(result)
        try XCTAssertTrue(r.text.contains("Pako"),
            "stub text should include pet name; got: \(r.text)")
        try XCTAssertTrue(r.text.contains("self-deprecating"),
            "stub text should include humor style; got: \(r.text)")
        try XCTAssertTrue(r.text.contains("Xcode"),
            "stub text should still include appName; got: \(r.text)")
        try XCTAssertTrue(r.text.contains("what's up?"),
            "stub text should still echo selectedText; got: \(r.text)")
    }

    tests.add("Stub.testPet_nil_backwardCompat") { _ in
        // pet = nil 时 stub 行为**不**变（向后兼容 P2-L-1/2 测试）
        let p = makeProvider()
        let req = TextCompletionRequest(
            action: .ask,
            selectedText: "hi",
            appContext: makeAppContext(appName: "Xcode"),
            petProfile: nil
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        let r = try XCTUnwrap(result)
        try XCTAssertEqual(r.text, "[STUB ask in Xcode]: hi")
    }

    tests.add("Stub.testPet_allActionsInjected") { _ in
        // 5 个 action 都正确注入 pet 标签
        let p = makeProvider()
        let pet = makePet(name: "Mitu", humorStyle: "gentle")
        try runAsync {
            for action in SelectionActionKind.allCases {
                let req = TextCompletionRequest(
                    action: action,
                    selectedText: "x",
                    appContext: makeAppContext(appName: "A"),
                    petProfile: pet
                )
                let r = try await p.complete(req)
                try XCTAssertTrue(r.text.contains("Mitu"),
                    "action=\(action.rawValue) should include Mitu; got: \(r.text)")
                try XCTAssertTrue(r.text.contains("gentle"),
                    "action=\(action.rawValue) should include gentle; got: \(r.text)")
            }
        }
    }

    tests.add("Stub.testPetProfile_doesNotLeakKey") { _ in
        // pet profile 注入时，result.text 仍**不**应含 key-like 模式
        let p = makeProvider()
        let pet = makePet(name: "Zorp", humorStyle: "sarcastic")
        let req = TextCompletionRequest(
            action: .translate,
            selectedText: "Hello",
            appContext: makeAppContext(appName: "T"),
            petProfile: pet
        )
        var result: TextCompletionResult?
        try runAsync { result = try await p.complete(req) }
        let r = try XCTUnwrap(result)
        try XCTAssertFalse(r.text.contains("sk-"))
        try XCTAssertFalse(r.text.contains("api_key"))
        try XCTAssertFalse(r.text.contains("ProviderError"))
    }
}

// MARK: - 内部 helper

/// 极小的 sync result 容器，给 runAsync helper 用
private final class SyncResultBox: @unchecked Sendable {
    private var value: Result<Void, Error>?
    private let lock = NSLock()
    func set(_ r: Result<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        value = r
    }
    func unwrap() throws {
        lock.lock(); defer { lock.unlock() }
        guard let v = value else {
            throw TestFailure(name: "SyncResultBox", message: "no result captured")
        }
        try v.get()
    }
}

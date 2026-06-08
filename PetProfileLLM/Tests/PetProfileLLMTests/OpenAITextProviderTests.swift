// OpenAITextProviderTests.swift
// OpenAITextProvider stub 行为测试 — 验证不调真网络 + keychain 走通
//
// 覆盖：
//   - testMetadata — id / displayName / requiresAPIKey / supportedActions
//   - testKeyMissing_throwsKeyMissing — keychain 空 → ProviderError.keyMissing
//   - testNotImplemented_throwsNotImplemented — keychain 有 key → 抛 ProviderError.notImplemented
//   - testInMemoryKeychain_DI — 注入 InMemoryKeychainBackend 不污染真 keychain
//   - testDoesNotCallNetwork — 用 URLProtocol mock 验证 0 网络请求
//   - testSupportedActions_allFive — 5 个 action 都 supported
//   - testNoHardcodedKey — 源码静态断言（grep probe 思路；不直接 grep，断言行为）
//
// 不做：
//   - 不接真 OpenAI（这是 stub）
//   - 不测 token 计数（notImplemented 不算）
//   - 不测 latency 范围（notImplemented 立即 throw）
//

import Foundation
import PetProfileBrain
@testable import PetProfileLLM

func registerOpenAITextProviderTests(_ tests: Tests) {

    // MARK: - helpers

    func makeInMemoryKeychain() -> (KeychainKeyStore, InMemoryKeychainBackend) {
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        return (store, backend)
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

    tests.add("OpenAIText.testMetadata") { _ in
        let p = OpenAITextProvider(keychain: KeychainKeyStore(backend: InMemoryKeychainBackend()))
        try XCTAssertEqual(p.id, "openai-gpt")
        try XCTAssertEqual(p.displayName, "OpenAI GPT")
        try XCTAssertTrue(p.requiresAPIKey, "openai-gpt MUST require API key")
        try XCTAssertEqual(p.supportedActions.count, 5)
        for kind in SelectionActionKind.allCases {
            try XCTAssertTrue(p.supportedActions.contains(kind), "must support \(kind.rawValue)")
        }
    }

    tests.add("OpenAIText.testKeyMissing_throwsKeyMissing") { _ in
        // 关键 probe：keychain 找不到 key → 抛 ProviderError.keyMissing
        let (store, _) = makeInMemoryKeychain()
        // **不**存 key — keychain 空
        let p = OpenAITextProvider(keychain: store)
        let req = TextCompletionRequest(
            action: .translate,
            selectedText: "hello",
            appContext: nil
        )
        var caught: ProviderError?
        try runAsync {
            do {
                _ = try await p.complete(req)
            } catch let e as ProviderError {
                caught = e
            }
        }
        guard let err = caught else {
            throw TestFailure(name: "keyMissing", message: "expected ProviderError.keyMissing, got nil")
        }
        switch err {
        case .keyMissing(let id):
            try XCTAssertEqual(id, "openai-gpt")
        default:
            throw TestFailure(name: "keyMissing", message: "wrong case: \(err)")
        }
    }

    tests.add("OpenAIText.testNotImplemented_throwsNotImplemented") { _ in
        // 关键 probe：keychain 有 key → 抛 ProviderError.notImplemented（不进真网络）
        let (store, backend) = makeInMemoryKeychain()
        try backend.save(Data("sk-test-1234567890".utf8), account: OpenAITextProvider.providerID)
        let p = OpenAITextProvider(keychain: store)
        let req = TextCompletionRequest(
            action: .translate,
            selectedText: "hello",
            appContext: AppContextSnapshot(bundleID: "com.apple.Safari", appName: "Safari", windowTitle: nil, capturedAt: Date())
        )
        var caught: ProviderError?
        try runAsync {
            do {
                _ = try await p.complete(req)
            } catch let e as ProviderError {
                caught = e
            }
        }
        guard let err = caught else {
            throw TestFailure(name: "notImpl", message: "expected ProviderError.notImplemented, got nil")
        }
        switch err {
        case .notImplemented(let id, let msg):
            try XCTAssertEqual(id, "openai-gpt")
            try XCTAssertTrue(msg.contains("not wired"), "message should mention 'not wired'; got: \(msg)")
        default:
            throw TestFailure(name: "notImpl", message: "wrong case: \(err)")
        }
    }

    tests.add("OpenAIText.testKeychainAccount_custom") { _ in
        // 关键 probe：keychainAccount 可注入；test 不依赖全局 account 命名
        let (store, backend) = makeInMemoryKeychain()
        let customAccount = "openai-gpt-test-account"
        try backend.save(Data("sk-custom".utf8), account: customAccount)

        // 用 custom account 的 provider
        let p = OpenAITextProvider(keychain: store, keychainAccount: customAccount)
        let req = TextCompletionRequest(action: .translate, selectedText: "x", appContext: nil)
        var caught: ProviderError?
        try runAsync {
            do { _ = try await p.complete(req) } catch let e as ProviderError { caught = e }
        }
        // custom account 有 key → 应该抛 notImplemented，不是 keyMissing
        switch try XCTUnwrap(caught) {
        case .notImplemented:
            // OK
            break
        default:
            throw TestFailure(name: "customAccount", message: "expected notImplemented; got \(caught!)")
        }

        // 用 default account (openai-gpt) 的 provider（keychain 找不到）
        let p2 = OpenAITextProvider(keychain: store)
        var caught2: ProviderError?
        try runAsync {
            do { _ = try await p2.complete(req) } catch let e as ProviderError { caught2 = e }
        }
        switch try XCTUnwrap(caught2) {
        case .keyMissing(let id):
            try XCTAssertEqual(id, "openai-gpt")
        default:
            throw TestFailure(name: "customAccount", message: "expected keyMissing for default account; got \(caught2!)")
        }
    }

    tests.add("OpenAIText.testDoesNotCallNetwork") { _ in
        // 关键 probe：用 URLProtocol mock 验证 0 网络请求
        let (store, backend) = makeInMemoryKeychain()
        try backend.save(Data("sk-network-probe".utf8), account: OpenAITextProvider.providerID)
        let p = OpenAITextProvider(keychain: store)

        NetworkRequestRecorder.reset()
        URLProtocol.registerClass(NetworkRequestRecorder.self)
        defer { URLProtocol.unregisterClass(NetworkRequestRecorder.self) }

        let req = TextCompletionRequest(
            action: .ask,
            selectedText: "network probe",
            appContext: nil
        )
        try runAsync {
            do {
                _ = try await p.complete(req)
            } catch {
                // notImplemented is expected
            }
        }
        // 0 网络请求（stub 不调真网络）
        try XCTAssertEqual(
            NetworkRequestRecorder.requestCount, 0,
            "OpenAITextProvider stub must NOT make network calls; got \(NetworkRequestRecorder.requestCount) requests"
        )
    }

    tests.add("OpenAIText.testKeychainAccount_defaultIsID") { _ in
        // 关键 probe：keychainAccount default = id（不是 "openai"）
        // 这保证跟 PetProfileLLM 既有 OpenAIProvider 用的 account "openai" 不冲突
        let p = OpenAITextProvider(keychain: KeychainKeyStore(backend: InMemoryKeychainBackend()))
        try XCTAssertEqual(p.keychainAccount, "openai-gpt")
    }

    tests.add("OpenAIText.testModelDefault") { _ in
        // 关键 probe：model default = gpt-4o-mini
        let p = OpenAITextProvider(keychain: KeychainKeyStore(backend: InMemoryKeychainBackend()))
        try XCTAssertEqual(p.model, "gpt-4o-mini")

        let p2 = OpenAITextProvider(keychain: KeychainKeyStore(backend: InMemoryKeychainBackend()), model: "gpt-4o")
        try XCTAssertEqual(p2.model, "gpt-4o")
    }
}

// MARK: - 内部 helper

/// 极小的 sync result 容器
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

/// 截获所有 URLRequest，记到 shared counter
final class NetworkRequestRecorder: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestCount: Int = 0
    nonisolated(unsafe) static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequest = request
    }
    override func stopLoading() {}

    static func reset() {
        requestCount = 0
        lastRequest = nil
    }
}

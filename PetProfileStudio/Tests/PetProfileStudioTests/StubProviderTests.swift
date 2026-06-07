// StubProviderTests.swift
// AI stub provider 行为测试 — 验证不调真网络
//
// 覆盖：
//   - testOpenAIDALLEStubDoesNotCallNetwork — OpenAIDALLE.generate 抛 notImplemented；
//     用 URLProtocol mock 验证 0 网络请求
//   - testStableDiffusionStubDoesNotCallNetwork — StableDiffusion 同上
//
// 策略：
//   - URLProtocol.registerClass 把 FakeNetworkProtocol 插到 URLSession 的 protocolClasses
//   - FakeNetworkProtocol 把所有请求记下来
//   - Provider.generate() 应该**不**用 URLSession（因为是 stub），所以 0 请求
//   - 反向断言：如果未来重构错误地接了真网络，URLProtocol 会 catch 到
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

// MARK: - URLProtocol 记录器

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
        // 不调 urlLoadingDelegate —— 不让任何真网络流量出去
    }
    override func stopLoading() {}

    static func reset() {
        requestCount = 0
        lastRequest = nil
    }
}

func registerStubProviderTests(_ tests: Tests) {
    // MARK: - 共享 fixture

    /// 注册 URLProtocol 截获网络；结束后 unregister
    func withNetworkRecorder<R>(_ body: () async throws -> R) async throws -> R {
        NetworkRequestRecorder.reset()
        URLProtocol.registerClass(NetworkRequestRecorder.self)
        defer { URLProtocol.unregisterClass(NetworkRequestRecorder.self) }
        return try await body()
    }

    /// 标准 5 state request（URLs 任意 — stub 不读）
    func makeRequest() -> ImageGenerationRequest {
        ImageGenerationRequest(
            petID: "pet_test01",
            states: VisualState.allCases,
            prompt: "stub test prompt",
            referenceImageURLs: [],
            uploadURLs: (0..<5).map { URL(fileURLWithPath: "/tmp/stub-\($0).png") }
        )
    }

    // MARK: - 测试

    tests.add("Stub.testOpenAIDALLEStubDoesNotCallNetwork") { _ in
        let provider = OpenAIDALLEImageProvider()
        try XCTAssertEqual(provider.id, "openai-dalle")
        try XCTAssertTrue(provider.requiresAPIKey, "openai-dalle must require API key")
        try XCTAssertEqual(provider.displayName, "OpenAI DALL-E")

        _ = try await withNetworkRecorder {
            do {
                _ = try await provider.generate(request: makeRequest())
                throw TestFailure(name: "stub-openai", message: "expected throw notImplemented")
            } catch let e as ImageProviderError {
                switch e {
                case .notImplemented(let id, _):
                    try XCTAssertEqual(id, "openai-dalle")
                default:
                    throw TestFailure(name: "stub-openai", message: "wrong case: \(e)")
                }
            } catch {
                throw TestFailure(name: "stub-openai", message: "wrong error: \(error)")
            }
        }
        // 关键：0 网络请求
        try XCTAssertEqual(
            NetworkRequestRecorder.requestCount, 0,
            "stub must NOT make network calls; got \(NetworkRequestRecorder.requestCount) requests"
        )
    }

    tests.add("Stub.testStableDiffusionStubDoesNotCallNetwork") { _ in
        let provider = StableDiffusionImageProvider()
        try XCTAssertEqual(provider.id, "stable-diffusion")
        try XCTAssertTrue(provider.requiresAPIKey, "stable-diffusion must require API key")
        try XCTAssertEqual(provider.displayName, "Stable Diffusion")

        _ = try await withNetworkRecorder {
            do {
                _ = try await provider.generate(request: makeRequest())
                throw TestFailure(name: "stub-sd", message: "expected throw notImplemented")
            } catch let e as ImageProviderError {
                switch e {
                case .notImplemented(let id, _):
                    try XCTAssertEqual(id, "stable-diffusion")
                default:
                    throw TestFailure(name: "stub-sd", message: "wrong case: \(e)")
                }
            } catch {
                throw TestFailure(name: "stub-sd", message: "wrong error: \(error)")
            }
        }
        // 关键：0 网络请求
        try XCTAssertEqual(
            NetworkRequestRecorder.requestCount, 0,
            "stub must NOT make network calls; got \(NetworkRequestRecorder.requestCount) requests"
        )
    }
}

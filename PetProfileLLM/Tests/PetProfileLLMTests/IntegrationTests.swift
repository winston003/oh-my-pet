// IntegrationTests.swift
// PetProfileLLM ↔ PetProfileBrain 集成测试
//
// 覆盖（per spec）：
//   - 跟 PetProfileBrain 集成（用 MockLLM 跑全链路 — 真 LLM 不在测试环境跑）
//   - RealLLMFactory 选 provider 正确（用 InMemoryKeychainBackend）
//   - RealLLMFactory 找不到 key → .unauthorized
//   - RealLLMFactory 不识别 provider → .unknownProvider
//   - RealLLMFactory openai-compatible 缺 model → .modelRequired
//   - SyncLLMProviderAdapter 桥接 async → sync
//   - 3 pet × 1 场景 端到端（fixture 模式）
//
// 越界检查：
//   - 不改 PetProfileBrain / PetProfileKit / PetProfileOnboarding 任何文件（frozen）
//   - 不调真 LLM
//   - 不写真 keychain（用 InMemoryKeychainBackend）
//

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain
@testable import PetProfileLLM

// MARK: - helper: ChannelSink 记录

final class IntegrationTestSink: ChannelSink {
    var expressionCalls: [VisualState] = []
    var actionCalls: [ActionReaction] = []
    var audioCalls: [String] = []
    var audioNilCount: Int = 0

    func playExpression(_ state: VisualState) { expressionCalls.append(state) }
    func playAction(_ reaction: ActionReaction) { actionCalls.append(reaction) }
    func playAudio(_ catchphrase: AudioCatchphrase?) {
        if let cp = catchphrase { audioCalls.append(cp.text) }
        else { audioNilCount += 1 }
    }
}

// MARK: - helper: profile 加载（复制到 tmp）

func copyLLMTestFixtureToTmp(_ name: String) throws -> URL {
    guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/Profiles") else {
        throw NSError(
            domain: "IntegrationTestLoader", code: 404,
            userInfo: [NSLocalizedDescriptionKey: "missing fixture \(name).json in Fixtures/Profiles"]
        )
    }
    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pet-llm-int-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    let dest = tmpRoot.appendingPathComponent("\(name).json")
    try FileManager.default.copyItem(at: url, to: dest)
    return dest
}

func loadPakoProfileForIntegration() throws -> LoadedPetProfile {
    let url = try copyLLMTestFixtureToTmp("pako-v1.0.0")
    return try PetProfileLoader().loadProfile(from: url)
}
func loadMituProfileForIntegration() throws -> LoadedPetProfile {
    let url = try copyLLMTestFixtureToTmp("mitu-v1.0.0")
    return try PetProfileLoader().loadProfile(from: url)
}
func loadZorpProfileForIntegration() throws -> LoadedPetProfile {
    let url = try copyLLMTestFixtureToTmp("zorp-v1.0.0")
    return try PetProfileLoader().loadProfile(from: url)
}

// MARK: - helper: MockLLM 从 fixture 加载

func makeMockLLMFromBundle(pet: String) throws -> MockLLM {
    let prefix = "\(pet)-"
    let subdir = "Fixtures/LLMResponses"
    guard let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: subdir) else {
        throw NSError(domain: "MockLLM", code: 404, userInfo: [NSLocalizedDescriptionKey: "no LLMResponses fixtures"])
    }
    let matched = urls.filter { $0.lastPathComponent.hasPrefix(prefix) }
    if matched.isEmpty {
        throw NSError(domain: "MockLLM", code: 404, userInfo: [NSLocalizedDescriptionKey: "no fixtures for pet \(pet)"])
    }
    var fixtures: [MockLLMFixture] = []
    for url in matched.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let data = try Data(contentsOf: url)
        let f = try JSONDecoder().decode(MockLLMFixture.self, from: data)
        fixtures.append(f)
    }
    return MockLLM(fixtures: fixtures)
}

func registerIntegrationTests(_ tests: Tests) {

    // MARK: - PetProfileBrain 全链路

    tests.add("Integration.testPako_comfort_endToEnd") { _ in
        let profile = try loadPakoProfileForIntegration()
        let llm = try makeMockLLMFromBundle(pet: "pako")
        let sink = IntegrationTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "我累了")
        try XCTAssertContains(response.text, "嗯")
        try XCTAssertEqual(response.expression, .happy)
        try XCTAssertEqual(response.action?.name, "jelly-bounce")
        try XCTAssertEqual(response.audioCatchphrase?.text, "没事，慢慢来")
        try XCTAssertEqual(sink.audioCalls, ["没事，慢慢来"])
    }

    tests.add("Integration.testMitu_celebrate_endToEnd") { _ in
        let profile = try loadMituProfileForIntegration()
        let llm = try makeMockLLMFromBundle(pet: "mitu")
        let sink = IntegrationTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "task done")
        try XCTAssertEqual(response.expression, .celebrate)
        try XCTAssertEqual(response.action?.name, "curl-into-ball")
        try XCTAssertEqual(response.audioCatchphrase?.text, "辛苦了")
    }

    tests.add("Integration.testZorp_bugMeme_endToEnd") { _ in
        let profile = try loadZorpProfileForIntegration()
        let llm = try makeMockLLMFromBundle(pet: "zorp")
        let sink = IntegrationTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "这个 bug 写不出来了")
        try XCTAssertEqual(response.text, "这 bug 不赖我。")
        try XCTAssertEqual(response.action?.name, "tentacle-slap")
        try XCTAssertEqual(response.audioCatchphrase?.text, "这 bug 不赖我")
    }

    // MARK: - RealLLMFactory

    tests.add("Integration.testFactory_openai_succeeds") { _ in
        let backend = InMemoryKeychainBackend()
        try backend.save(Data("sk-factory-test".utf8), account: "openai")
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        let p = try factory.create(provider: "openai", session: URLSession.shared)
        try XCTAssertEqual(p.name, "openai")
    }

    tests.add("Integration.testFactory_claude_succeeds") { _ in
        let backend = InMemoryKeychainBackend()
        try backend.save(Data("sk-ant-factory-test".utf8), account: "claude")
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        let p = try factory.create(provider: "claude", session: URLSession.shared)
        try XCTAssertEqual(p.name, "claude")
    }

    tests.add("Integration.testFactory_openaiCompatible_succeeds") { _ in
        let backend = InMemoryKeychainBackend()
        try backend.save(Data("local-key".utf8), account: "openai-compatible:http://localhost:11434")
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        let p = try factory.create(
            provider: "openai-compatible:http://localhost:11434",
            model: "llama3",
            session: URLSession.shared
        )
        try XCTAssertEqual(p.name, "openai-compatible:http://localhost:11434")
    }

    tests.add("Integration.testFactory_openaiCompatible_noKey_usesNil") { _ in
        // Ollama 本地服务没有 key — keychain 找不到也不抛错
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        let p = try factory.create(
            provider: "openai-compatible:http://localhost:11434",
            model: "llama3",
            session: URLSession.shared
        )
        try XCTAssertEqual(p.name, "openai-compatible:http://localhost:11434")
    }

    tests.add("Integration.testFactory_openai_missingKey_throwsUnauthorized") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        do {
            _ = try factory.create(provider: "openai")
            throw TestFailure(name: "factory-401", message: "expected throw")
        } catch let err as PetProfileLLM.LLMError {
            if case .unauthorized = err { return }
            throw TestFailure(name: "factory-401", message: "expected .unauthorized, got \(err)")
        } catch {
            throw TestFailure(name: "factory-401", message: "expected PetProfileLLM.LLMError, got \(error)")
        }
    }

    tests.add("Integration.testFactory_unknownProvider_throwsRealLLMError") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        do {
            _ = try factory.create(provider: "gemini-flash")
            throw TestFailure(name: "factory-unknown", message: "expected throw")
        } catch let err as RealLLMError {
            if case .unknownProvider(let n) = err {
                try XCTAssertEqual(n, "gemini-flash")
                return
            }
            throw err
        }
    }

    tests.add("Integration.testFactory_openaiCompatible_missingModel_throwsModelRequired") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        let factory = RealLLMFactory(keychain: store)

        do {
            _ = try factory.create(provider: "openai-compatible:http://localhost:11434")
            throw TestFailure(name: "factory-nomodel", message: "expected throw")
        } catch let err as RealLLMError {
            if case .modelRequired = err { return }
            throw err
        }
    }

    // MARK: - SyncLLMProviderAdapter

    tests.add("Integration.testSyncAdapter_asyncProvider_becomesSync") { _ in
        // 用 URLProtocolMock 拦截
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }
        mock.setResponse(.json(["choices": [["message": ["content": "from real async provider"]]]]))
        let session = mock.makeSession()
        let asyncProvider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)
        let sync = SyncLLMProviderAdapter(wrapping: asyncProvider)

        // sync LLMProvider 的 complete() 应该能跑（semaphore 等 async）
        let text = try sync.complete(prompt: "hi")
        try XCTAssertEqual(text, "from real async provider")
    }

    tests.add("Integration.testSyncAdapter_inBrain_fullFlow") { _ in
        // 用真 OpenAI（mock 拦截） + SyncLLMProviderAdapter + Brain.respond 全链路
        let mock = URLProtocolMock.shared
        mock.reset()
        mock.register()
        defer { mock.unregister() }
        mock.setResponse(.json(["choices": [
            ["message": ["content": "{\"text\": \"from real provider\", \"expression\": \"happy\", \"action\": \"jelly-bounce\", \"audio_catchphrase\": \"嘛，又周五了吗\"}"]]
        ]]))
        let session = mock.makeSession()
        let asyncProvider = OpenAIProvider(apiKey: "sk-test", session: session, retryBaseDelay: 0)
        let sync = SyncLLMProviderAdapter(wrapping: asyncProvider)

        let profile = try loadPakoProfileForIntegration()
        let sink = IntegrationTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: sync, dispatcher: dispatcher)

        let response = try brain.respond(to: "周五")
        try XCTAssertEqual(response.text, "from real provider")
        try XCTAssertEqual(response.expression, .happy)
        try XCTAssertEqual(response.action?.name, "jelly-bounce")
        try XCTAssertEqual(response.audioCatchphrase?.text, "嘛，又周五了吗")
        try XCTAssertEqual(sink.expressionCalls, [.happy])
        try XCTAssertEqual(sink.audioCalls, ["嘛，又周五了吗"])
    }

    // MARK: - AsyncLLMProviderAdapter (反向)

    tests.add("Integration.testAsyncAdapter_syncMock_becomesAsync") { _ in
        // 用临时 JSON 反序列化成 MockLLMFixture（frozen 类型无 memberwise init）
        let json = """
        {
          "text": "async from sync mock",
          "expression": "happy",
          "action": null,
          "audio_catchphrase": null,
          "_match_keywords": ["async"]
        }
        """.data(using: .utf8)!
        let fixture = try JSONDecoder().decode(MockLLMFixture.self, from: json)
        let mock = MockLLM(fixtures: [fixture])
        let asyncWrapped = AsyncLLMProviderAdapter(wrapping: mock)
        try XCTAssertEqual(asyncWrapped.name, "MockLLM")  // type name fallback

        try XCTAssertAsync {
            let text = try await asyncWrapped.complete(prompt: "## User 说\nasync\n\n## 请按 5 通道格式回复")
            try XCTAssertContains(text, "async from sync mock")
        }
    }
}

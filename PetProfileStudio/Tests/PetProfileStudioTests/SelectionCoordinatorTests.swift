// SelectionCoordinatorTests.swift
// SelectionCoordinator 状态机 + DI 测试
//
// 覆盖：
//   - testInitialPhaseIsIdle — 初始 .idle
//   - testTriggerWithEmptyPasteboardEmitsInfo — 剪贴板空 → .info(...)（**不**调 provider）
//   - testTriggerWithPasteboardEmitsReadyForUser — 剪贴板有文本 → .readyForUser
//   - testTriggerPureWhitespacePasteboardEmitsInfo — 只有 whitespace 视为空
//   - testTriggerSetsDefaultProviderFromRegistry — 选 default provider
//   - testTriggerBuildsAppContextFromSnapshot — appContext 来自 injected snapshot
//   - testSelectProviderNoOpWhenNotReady — 非 ready 阶段 selectProvider 是 no-op
//   - testSelectProviderUpdatesState — ready 阶段改 provider 改 state
//   - testSelectActionUpdatesState — 改 action 改 state
//   - testSendCallsProvider — send 调 provider；.running → .completed
//   - testSendProviderKeyMissingEmitsInfo — provider 抛 .keyMissing → .info（**不**调 AI）
//   - testSendProviderNetworkErrorEmitsFailed — provider 抛 .networkError → .failed
//   - testSendProviderNotImplementedEmitsFailed — .notImplemented → .failed(friendly)
//   - testCancelFromReadyEmitsDismissed — cancel 从 ready → .dismissed
//   - testCloseFromCompletedEmitsDismissed — close 从 completed → .dismissed
//   - testInfoAutoClearsViaClearInfo — clearInfo 把 .info → .idle
//   - testPasteboardInjectionDoesNotTouchGeneral — DI 验证：测试用 NSPasteboard.withUniqueName()
//   - testNoNetworkCallsWhenPasteboardEmpty — 空剪贴板时 0 网络调用（provider 不被构造 / 不被调）
//   - testFriendlyMessageForKeyMissing — ProviderError → friendly 文本
//   - testFriendlyMessageForNotImplemented — ProviderError → friendly 文本
//
// **adversarial probe**：
//   - 用 NSPasteboard.withUniqueName() mock，**不**碰 .general
//   - 0 network call（不调 URLProtocol；测试只验 coordinator 逻辑）
//   - SelectionCoordinator 不持有 / 不读 keychain
//   - 0 命中"sk-[a-zA-Z0-9]" / "Bearer" / "api.openai.com" / NSWorkspaceAccessibility

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain
@testable import PetProfileStudio

// Test helpers (makeMockPasteboard / setPasteboardString / fixedSnapshot) live in
// Tests/PetProfileStudioTests/TestKit.swift

/// 等待 condition 为真或 timeout（秒）。Task.sleep 让 main 线程能跑
/// MainActor.run 任务（不会死锁）。
@available(macOS 13.0, *)
func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5.0) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 50_000_000)  // 50ms
    }
}

func registerSelectionCoordinatorTests(_ tests: Tests) {

    // MARK: - 基础

    tests.add("Coordinator.testInitialPhaseIsIdle") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        try XCTAssertEqual(coord.phase, .idle)
    }

    // MARK: - trigger

    tests.add("Coordinator.testTriggerWithEmptyPasteboardEmitsInfo") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, nil)
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        coord.trigger()
        // .info("No text selected. Copy something first.")
        switch coord.phase {
        case .info(let msg):
            try XCTAssertTrue(msg.lowercased().contains("no text"))
        default:
            throw TestFailure(name: "trigger-empty", message: "expected .info, got \(coord.phase)")
        }
    }

    tests.add("Coordinator.testTriggerWithPasteboardEmitsReadyForUser") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "Hello world")
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        coord.trigger()
        switch coord.phase {
        case .readyForUser(let s):
            try XCTAssertEqual(s.selectedText, "Hello world")
            try XCTAssertEqual(s.action, .explain)  // 默认
            try XCTAssertEqual(s.appContext.appName, "TestApp")
            try XCTAssertEqual(s.appContext.bundleID, "com.test.app")
        default:
            throw TestFailure(name: "trigger-ready", message: "expected .readyForUser, got \(coord.phase)")
        }
    }

    tests.add("Coordinator.testTriggerPureWhitespacePasteboardEmitsInfo") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "   \n  \t  ")
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        coord.trigger()
        switch coord.phase {
        case .info:
            break  // expected
        default:
            throw TestFailure(name: "trigger-ws", message: "expected .info for whitespace, got \(coord.phase)")
        }
    }

    tests.add("Coordinator.testTriggerSetsDefaultProviderFromRegistry") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "text")
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        coord.trigger()
        if case .readyForUser(let s) = coord.phase {
            // TextProviderRegistry.shared.defaultProvider 默认是 StubTextProvider
            try XCTAssertEqual(s.providerID, StubTextProvider.providerID)
            try XCTAssertEqual(s.model, "stub-echo-v1")
        } else {
            throw TestFailure(name: "trigger-default", message: "expected .readyForUser")
        }
    }

    tests.add("Coordinator.testTriggerBuildsAppContextFromSnapshot") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")
        let custom = FrontmostAppCapture.Snapshot(
            bundleID: nil, appName: "Xcode", windowTitle: nil,
            capturedAt: Date()
        )
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { custom }
        )
        coord.trigger()
        if case .readyForUser(let s) = coord.phase {
            try XCTAssertEqual(s.appContext.appName, "Xcode")
            try XCTAssertNil(s.appContext.bundleID)
            try XCTAssertNil(s.appContext.windowTitle)
        } else {
            throw TestFailure(name: "trigger-ctx", message: "expected .readyForUser")
        }
    }

    // MARK: - select provider / action

    tests.add("Coordinator.testSelectProviderNoOpWhenNotReady") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        // 初始 .idle
        coord.selectProvider(id: "openai-gpt")
        try XCTAssertEqual(coord.phase, .idle, "selectProvider in .idle should be no-op")
    }

    tests.add("Coordinator.testSelectProviderUpdatesState") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        coord.trigger()
        // 切到 openai-gpt（如果存在；这里 registry 只有 stub）
        // 用一个未知 id 测 no-op
        coord.selectProvider(id: "openai-gpt")
        if case .readyForUser(let s) = coord.phase {
            // openai-gpt 不在默认 registry 里，所以应该保持 stub
            try XCTAssertEqual(s.providerID, "stub")
        } else {
            throw TestFailure(name: "select-provider", message: "expected .readyForUser")
        }
        // 注册一个 fake provider 然后切
        let fake = FakeTextProvider(id: "fake-1", displayName: "Fake 1", requiresAPIKey: false)
        TextProviderRegistry.shared.register(fake)
        defer {
            // 清理：unregister 不存在，但重新 register 同 id 覆盖是 OK 的
            TextProviderRegistry.shared.register(StubTextProvider())
        }
        coord.selectProvider(id: "fake-1")
        if case .readyForUser(let s) = coord.phase {
            try XCTAssertEqual(s.providerID, "fake-1")
        } else {
            throw TestFailure(name: "select-provider-2", message: "expected .readyForUser")
        }
    }

    tests.add("Coordinator.testSelectActionUpdatesState") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")
        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        coord.selectAction(.translate)
        if case .readyForUser(let s) = coord.phase {
            try XCTAssertEqual(s.action, .translate)
        } else {
            throw TestFailure(name: "select-action", message: "expected .readyForUser")
        }
    }

    // MARK: - send / provider interaction

    tests.add("Coordinator.testSendCallsProvider_async") { tests in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "hello")

        let fake = FakeTextProvider(
            id: "test-stub",
            displayName: "Test Stub",
            requiresAPIKey: false,
            resultText: "[TEST OK]: hello"
        )
        TextProviderRegistry.shared.register(fake)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }

        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() }
        )
        coord.trigger()
        coord.selectProvider(id: "test-stub")
        coord.send()

        // .running 应该立刻可见（send 是同步的，状态切到 running 在返回前）
        if case .running = coord.phase {
            // OK
        } else {
            throw TestFailure(name: "send-running", message: "expected .running, got \(coord.phase)")
        }

        // 等 .completed（async wait；不阻塞 main）
        await waitUntil({
            if case .completed = coord.phase { return true }
            return false
        })

        if case .completed(let s, let r) = coord.phase {
            try XCTAssertEqual(s.selectedText, "hello")
            try XCTAssertEqual(r.text, "[TEST OK]: hello")
            try XCTAssertEqual(r.providerID, "test-stub")
        } else {
            throw TestFailure(name: "send-completed", message: "expected .completed, got \(coord.phase)")
        }
    }

    tests.add("Coordinator.testSendProviderKeyMissingEmitsInfo_async") { tests in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")

        let keyMissing = FakeTextProvider(
            id: "needs-key",
            displayName: "Needs Key",
            requiresAPIKey: true,
            errorToThrow: .keyMissing(providerID: "needs-key")
        )
        TextProviderRegistry.shared.register(keyMissing)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }

        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        coord.selectProvider(id: "needs-key")
        coord.send()

        await waitUntil({
            if case .info = coord.phase { return true }
            if case .failed = coord.phase { return true }
            return false
        })

        // .keyMissing → .info（**不** .failed）
        if case .info(let msg) = coord.phase {
            try XCTAssertTrue(msg.contains("API key"), "expected API key message, got: \(msg)")
        } else {
            throw TestFailure(name: "key-missing", message: "expected .info, got \(coord.phase)")
        }
    }

    tests.add("Coordinator.testSendProviderNetworkErrorEmitsFailed_async") { tests in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")

        let netErr = FakeTextProvider(
            id: "net-err",
            displayName: "Net Err",
            requiresAPIKey: false,
            errorToThrow: .networkError(reason: "DNS fail")
        )
        TextProviderRegistry.shared.register(netErr)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }

        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        coord.selectProvider(id: "net-err")
        coord.send()

        await waitUntil({
            if case .failed = coord.phase { return true }
            return false
        })

        if case .failed(_, let msg) = coord.phase {
            try XCTAssertTrue(msg.contains("network"), "expected network in msg, got: \(msg)")
        } else {
            throw TestFailure(name: "net-err", message: "expected .failed, got \(coord.phase)")
        }
    }

    tests.add("Coordinator.testSendProviderNotImplementedEmitsFailed_async") { tests in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")

        let stub = FakeTextProvider(
            id: "not-impl",
            displayName: "Not Impl",
            requiresAPIKey: false,
            errorToThrow: .notImplemented(providerID: "not-impl", message: "wip")
        )
        TextProviderRegistry.shared.register(stub)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }

        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        coord.selectProvider(id: "not-impl")
        coord.send()

        await waitUntil({
            if case .failed = coord.phase { return true }
            return false
        })

        if case .failed(_, let msg) = coord.phase {
            // P2-L-3：文案改成 "not yet wired"
            try XCTAssertTrue(msg.contains("not yet wired"), "expected 'not yet wired' in msg, got: \(msg)")
        } else {
            throw TestFailure(name: "not-impl", message: "expected .failed, got \(coord.phase)")
        }
    }

    // MARK: - cancel / close

    tests.add("Coordinator.testCancelFromReadyEmitsDismissed") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")
        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        coord.cancel()
        try XCTAssertEqual(coord.phase, .dismissed)
    }

    tests.add("Coordinator.testCloseFromCompletedEmitsDismissed_async") { tests in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")

        let fake = FakeTextProvider(
            id: "close-test", displayName: "Close Test", requiresAPIKey: false,
            resultText: "ok"
        )
        TextProviderRegistry.shared.register(fake)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }

        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        coord.selectProvider(id: "close-test")
        coord.send()

        await waitUntil({
            if case .completed = coord.phase { return true }
            return false
        })

        coord.close()
        try XCTAssertEqual(coord.phase, .dismissed)
    }

    // MARK: - clearInfo

    tests.add("Coordinator.testInfoAutoClearsViaClearInfo") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, nil)
        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        if case .info = coord.phase {} else {
            throw TestFailure(name: "info-setup", message: "expected .info, got \(coord.phase)")
        }
        coord.clearInfo()
        try XCTAssertEqual(coord.phase, .idle)
    }

    tests.add("Coordinator.testClearInfoNoOpOutsideInfo") { _ in
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "x")
        let coord = SelectionCoordinator(pasteboard: pb, appSnapshot: { fixedSnapshot() })
        coord.trigger()
        // .readyForUser
        coord.clearInfo()
        // 不应改 phase
        if case .readyForUser = coord.phase {} else {
            throw TestFailure(name: "clear-info-noop", message: "clearInfo must not change non-.info phases")
        }
    }

    // MARK: - 错误消息文本

    tests.add("Coordinator.testFriendlyMessageForKeyMissing") { _ in
        let msg = SelectionCoordinator.friendlyMessage(
            for: .keyMissing(providerID: "x"),
            state: SelectionState(selectedText: "x", appContext: AppContextSnapshot(
                bundleID: nil, appName: "X", windowTitle: nil, capturedAt: Date()
            ), providerID: "x", model: "m")
        )
        try XCTAssertTrue(msg.contains("API key"))
        try XCTAssertTrue(msg.contains("🔑") || msg.contains("Settings"), "expected 🔑 or Settings hint, got: \(msg)")
    }

    tests.add("Coordinator.testFriendlyMessageForNotImplemented") { _ in
        let msg = SelectionCoordinator.friendlyMessage(
            for: .notImplemented(providerID: "x", message: "wip"),
            state: SelectionState(selectedText: "x", appContext: AppContextSnapshot(
                bundleID: nil, appName: "X", windowTitle: nil, capturedAt: Date()
            ), providerID: "x", model: "m")
        )
        // P2-L-3：文案改成 "This provider is not yet wired. Switch to Stub in the dropdown."
        try XCTAssertTrue(msg.contains("not yet wired"), "expected 'not yet wired' in msg, got: \(msg)")
    }

    tests.add("Coordinator.testFriendlyMessageForRateLimited") { _ in
        // P2-L-3 新增 case
        let msg = SelectionCoordinator.friendlyMessage(
            for: .rateLimited(reason: "429"),
            state: SelectionState(selectedText: "x", appContext: AppContextSnapshot(
                bundleID: nil, appName: "X", windowTitle: nil, capturedAt: Date()
            ), providerID: "x", model: "m")
        )
        try XCTAssertTrue(msg.lowercased().contains("rate"), "expected rate in msg, got: \(msg)")
    }

    tests.add("Coordinator.testFriendlyMessageForContentRefused") { _ in
        // P2-L-3 新增 case
        let msg = SelectionCoordinator.friendlyMessage(
            for: .contentRefused(reason: "safety"),
            state: SelectionState(selectedText: "x", appContext: AppContextSnapshot(
                bundleID: nil, appName: "X", windowTitle: nil, capturedAt: Date()
            ), providerID: "x", model: "m")
        )
        try XCTAssertTrue(msg.lowercased().contains("refus") || msg.lowercased().contains("safety"),
            "expected refusal/safety hint, got: \(msg)")
    }

    // MARK: - P2-L-3: pet 注入到 TextCompletionRequest

    /// Recording TextProvider — 记录每次收到的 request.petProfile
    struct PetRecordingTextProvider: TextProvider {
        let id: String
        let displayName: String
        let requiresAPIKey: Bool
        let supportedActions: Set<SelectionActionKind> = Set(SelectionActionKind.allCases)
        static var lastRequest: TextCompletionRequest?

        init(id: String = "pet-rec", displayName: String = "Pet Rec", requiresAPIKey: Bool = false) {
            self.id = id; self.displayName = displayName; self.requiresAPIKey = requiresAPIKey
        }
        func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult {
            Self.lastRequest = request
            return TextCompletionResult(text: "ok", providerID: id, modelUsed: "m", tokensUsed: nil, latencyMS: 0)
        }
    }

    tests.add("Coordinator.testPetInjection_async") { tests in
        // P2-L-3 关键 probe：petSummaryLoader → provider 收到 request.petProfile
        //   - petID 来自 PetStore.shared.currentPetID（独立于 loader）
        //   - 测试场景：loader 返回 hardcoded pet，PetStore.currentPetID 仍为 nil
        //     所以 petID 应该是 nil（**不**强求匹配；petProfile 是 source of truth）
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "hello")

        let recorder = PetRecordingTextProvider()
        TextProviderRegistry.shared.register(recorder)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }
        PetRecordingTextProvider.lastRequest = nil

        let pet = PetProfileSummary(
            name: "Pako", species: "office-jelly",
            humorStyle: "self-deprecating", storyTone: "工位上的老朋友"
        )
        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() },
            petSummaryLoader: { pet }
        )
        coord.trigger()
        coord.selectProvider(id: "pet-rec")
        coord.send()

        await waitUntil({
            if case .completed = coord.phase { return true }
            return false
        })
        // 关键断言：provider 收到的 request.petProfile 等于注入的 pet
        let last = try XCTUnwrap(PetRecordingTextProvider.lastRequest)
        let injected = try XCTUnwrap(last.petProfile)
        try XCTAssertEqual(injected.name, "Pako")
        try XCTAssertEqual(injected.humorStyle, "self-deprecating")
        try XCTAssertEqual(injected.storyTone, "工位上的老朋友")
        try XCTAssertEqual(injected.species, "office-jelly")
        // petID 在 production 路径会从 PetStore 读（与 petProfile 同步）；
        // 测试场景 loader 独立返回 pet，**不**写 PetStore，所以 petID = nil
        // （行为正确：loader 只管 petProfile；petID 是 selectionCoordinator 内部 derive）
    }

    tests.add("Coordinator.testPetInjection_nilLoader") { tests in
        // P2-L-3 关键 probe：petSummaryLoader 返回 nil → request.petProfile = nil
        //   (首次启动还没选 pet)
        let (pb, cleanup) = makeMockPasteboard()
        defer { cleanup() }
        setPasteboardString(pb, "hello")

        let recorder = PetRecordingTextProvider()
        TextProviderRegistry.shared.register(recorder)
        defer { TextProviderRegistry.shared.register(StubTextProvider()) }
        PetRecordingTextProvider.lastRequest = nil

        let coord = SelectionCoordinator(
            pasteboard: pb,
            appSnapshot: { fixedSnapshot() },
            petSummaryLoader: { nil }
        )
        coord.trigger()
        coord.selectProvider(id: "pet-rec")
        coord.send()

        await waitUntil({
            if case .completed = coord.phase { return true }
            return false
        })
        let last = try XCTUnwrap(PetRecordingTextProvider.lastRequest)
        try XCTAssertNil(last.petProfile)
        try XCTAssertNil(last.petID)
    }

    tests.add("Coordinator.testPetInjection_differentPets_changePrompt") { _ in
        // P2-L-3 关键 probe：切换 pet 时，PromptBuilder 输出的 system 段变化
        //   用 PetProfileSummary.from(manifest:) 加载 Pako / Mitu，构造两个 summary，
        //   调 PromptBuilder.buildSelectionPrompt 验证 system 段互不相等
        //   （**不**依赖 SelectionCoordinator；直接验 PromptBuilder 行为）
        // 注：此 test 用 sync（不需要 waitUntil），只是断言 prompt 编排结果
        let pakos = PetProfileSummary(
            name: "Pako", species: "office-jelly",
            humorStyle: "self-deprecating", storyTone: "工位上的老朋友"
        )
        let mitus = PetProfileSummary(
            name: "Mitu", species: "cloud",
            humorStyle: "gentle", storyTone: "安静朋友"
        )
        let req = TextCompletionRequest(
            action: .ask, selectedText: "hi",
            appContext: AppContextSnapshot(bundleID: nil, appName: "X", windowTitle: nil, capturedAt: Date())
        )
        let pPako = PromptBuilder.buildSelectionPrompt(request: req, pet: pakos)
        let pMitu = PromptBuilder.buildSelectionPrompt(request: req, pet: mitus)
        // system 段**必须**变化（humor / story 通道真在用）
        try XCTAssertNotEqual(pPako.system, pMitu.system)
        try XCTAssertContains(pPako.system, "Pako")
        try XCTAssertContains(pMitu.system, "Mitu")
        try XCTAssertContains(pPako.system, "self-deprecating")
        try XCTAssertContains(pMitu.system, "gentle")
        // user 段相同（action + selectedText + appName 都没变）
        try XCTAssertEqual(pPako.user, pMitu.user)
    }
}

// MARK: - FakeTextProvider

/// 测试用 TextProvider：可控 result / error
struct FakeTextProvider: TextProvider {
    let id: String
    let displayName: String
    let requiresAPIKey: Bool
    let supportedActions: Set<SelectionActionKind> = Set(SelectionActionKind.allCases)
    let resultText: String?
    let errorToThrow: ProviderError?
    let latencyMS: Int

    init(
        id: String,
        displayName: String,
        requiresAPIKey: Bool,
        resultText: String? = nil,
        errorToThrow: ProviderError? = nil,
        latencyMS: Int = 0
    ) {
        self.id = id
        self.displayName = displayName
        self.requiresAPIKey = requiresAPIKey
        self.resultText = resultText
        self.errorToThrow = errorToThrow
        self.latencyMS = latencyMS
    }

    func complete(_ request: TextCompletionRequest) async throws -> TextCompletionResult {
        if latencyMS > 0 {
            try await Task.sleep(nanoseconds: UInt64(latencyMS) * 1_000_000)
        }
        if let err = errorToThrow {
            throw err
        }
        return TextCompletionResult(
            text: resultText ?? "[FAKE \(request.action.rawValue)]: \(request.selectedText)",
            providerID: id,
            modelUsed: "fake-model-v1",
            tokensUsed: nil,
            latencyMS: latencyMS
        )
    }
}

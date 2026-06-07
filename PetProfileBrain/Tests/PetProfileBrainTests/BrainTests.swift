// BrainTests.swift
// Brain 端到端测试 — 3 pet × 2 场景 = 6 case（用 MockLLM 跑全链路）
//
// 覆盖：
//   - Brain.respond() 走完 prompt → LLM → parse → resolve → dispatch 全链路
//   - ChannelDispatcher 把 expression / action / audio 都投到 sink
//   - catchphrase 触发 audio + expression 切换 + action 跑
//   - joke_density 体现在 prompt 里（Zorp 0.50 > Pako 0.40 > Mitu 0.05）
//   - action name lookup：命中 profile.action.reactions 里的 name → 包成 ActionReaction
//   - audio text lookup：命中 profile.audio.catchphrases 里的 text → 包成 AudioCatchphrase
//   - 未命中的 action / audio → 该通道 nil
//   - currentState / lastAction 在多次 respond 后被维护
//
// 越界检查：
//   - 不修改 PetProfileKit / PetProfileRuntime 任何文件
//   - Brain 只 import + 调 public API
//   - 通过 MockChannelSink（用 @testable import PetProfileRuntime）隔离 NSPanel
//

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
@testable import PetProfileBrain

// MARK: - MockChannelSink（Brain tests 用，复用 runtime 既有 mock）

final class BrainTestSink: ChannelSink {
    var expressionCalls: [VisualState] = []
    var actionCalls: [ActionReaction] = []
    var audioCalls: [String] = []
    var audioNilCount: Int = 0
    private(set) var lastOrder: [ChannelKind] = []

    func playExpression(_ state: VisualState) {
        expressionCalls.append(state)
        lastOrder.append(.expression)
    }
    func playAction(_ reaction: ActionReaction) {
        actionCalls.append(reaction)
        lastOrder.append(.action)
    }
    func playAudio(_ catchphrase: AudioCatchphrase?) {
        if let cp = catchphrase {
            audioCalls.append(cp.text)
        } else {
            audioNilCount += 1
        }
        lastOrder.append(.audio)
    }
    func reset() {
        expressionCalls.removeAll()
        actionCalls.removeAll()
        audioCalls.removeAll()
        audioNilCount = 0
        lastOrder.removeAll()
    }
}

func registerBrainTests(_ tests: Tests) {

    // MARK: - Brain end-to-end: 3 pet × 2 场景 = 6 case

    // Pako × 2
    tests.add("Brain.testPako_comfort_dispatchesAllChannels") { _ in
        let profile = try loadPakoProfile()
        let llm = try makeMockLLM(prefix: "pako-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "我累了")

        // 关键字 "累" 命中 pako-comfort fixture
        try XCTAssertContains(response.text, "嗯")
        // expression 被切
        try XCTAssertEqual(response.expression, .happy)
        // action name "jelly-bounce" 在 profile 里
        try XCTAssertNotNil(response.action)
        try XCTAssertEqual(response.action?.name, "jelly-bounce")
        try XCTAssertNotNil(response.action?.springParams, "spring-animation should resolve springParams")
        // audio text "没事，慢慢来" 在 profile audio.catchphrases 里
        try XCTAssertNotNil(response.audioCatchphrase)
        try XCTAssertEqual(response.audioCatchphrase?.text, "没事，慢慢来")
        try XCTAssertEqual(response.audioCatchphrase?.cooldownSeconds, 30)

        // ChannelDispatcher 全部触发
        try XCTAssertEqual(sink.expressionCalls, [.happy])
        try XCTAssertEqual(sink.actionCalls.count, 1)
        try XCTAssertEqual(sink.actionCalls.first?.name, "jelly-bounce")
        try XCTAssertEqual(sink.audioCalls, ["没事，慢慢来"])
        try XCTAssertEqual(sink.lastOrder, [.expression, .action, .audio])

        // state + lastAction 已更新
        try XCTAssertEqual(brain.currentState, .happy)
        try XCTAssertEqual(brain.lastAction, "jelly-bounce")
        try XCTAssertEqual(brain.respondCount, 1)
    }

    tests.add("Brain.testPako_joke_audioCatchphrasePlayed") { _ in
        let profile = try loadPakoProfile()
        let llm = try makeMockLLM(prefix: "pako-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "周五了！")

        // "周五" 命中 pako-joke
        try XCTAssertContains(response.text, "周五")
        // audio 触发
        try XCTAssertEqual(sink.audioCalls, ["嘛，又周五了吗"])
        // expression happy（来自 fixture）
        try XCTAssertEqual(sink.expressionCalls, [.happy])
    }

    // Mitu × 2
    tests.add("Brain.testMitu_comfort_actionFurShake") { _ in
        let profile = try loadMituProfile()
        let llm = try makeMockLLM(prefix: "mitu-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "task done")

        // "task done" 命中 mitu-celebrate
        try XCTAssertEqual(response.action?.name, "curl-into-ball")
        try XCTAssertEqual(response.audioCatchphrase?.text, "辛苦了")
        try XCTAssertEqual(response.expression, .celebrate)
        try XCTAssertEqual(sink.expressionCalls, [.celebrate])
        try XCTAssertEqual(sink.actionCalls.first?.name, "curl-into-ball")
    }

    tests.add("Brain.testMitu_gentle_noJoke") { _ in
        // Mitu 的 system prompt 不应该出现 joke 频率
        let profile = try loadMituProfile()
        let llm = try makeMockLLM(prefix: "mitu-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)
        let sys = brain.systemPrompt()
        // joke_density 0.05 应该出现在 prompt 里
        try XCTAssertContains(sys, "0.05")
        // "gentle" 语气
        try XCTAssertContains(sys, "gentle")
        // 走 end-to-end
        let response = try brain.respond(to: "嗯")
        try XCTAssertGreaterThanOrEqual(response.text.count, 1)
    }

    // Zorp × 2
    tests.add("Brain.testZorp_bug_memeAudio") { _ in
        let profile = try loadZorpProfile()
        let llm = try makeMockLLM(prefix: "zorp-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "这个 bug 写不出来了")

        // "bug" 命中 zorp-joke
        try XCTAssertEqual(response.text, "这 bug 不赖我。")
        try XCTAssertEqual(response.audioCatchphrase?.text, "这 bug 不赖我")
        try XCTAssertEqual(response.action?.name, "tentacle-slap")
        try XCTAssertEqual(sink.audioCalls, ["这 bug 不赖我"])
    }

    tests.add("Brain.testZorp_celebrate_sarcasticSpin") { _ in
        let profile = try loadZorpProfile()
        let llm = try makeMockLLM(prefix: "zorp-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        let response = try brain.respond(to: "done 写完了")

        // "done" 命中 zorp-celebrate
        try XCTAssertEqual(response.action?.name, "spin-rainbow")
        try XCTAssertEqual(response.expression, .celebrate)
        try XCTAssertNotNil(response.action?.springParams, "spin-rainbow has spring params")
    }

    // MARK: - joke_density 行为差异

    tests.add("Brain.testJokeDensityInPrompts") { _ in
        // 3 pet 的 system prompt 各自带不同 joke_density
        let pako = try loadPakoProfile()
        let mitu = try loadMituProfile()
        let zorp = try loadZorpProfile()
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)

        let pakoBrain = Brain(profile: pako, llm: try makeMockLLM(prefix: "pako-"), dispatcher: dispatcher)
        let mituBrain = Brain(profile: mitu, llm: try makeMockLLM(prefix: "mitu-"), dispatcher: dispatcher)
        let zorpBrain = Brain(profile: zorp, llm: try makeMockLLM(prefix: "zorp-"), dispatcher: dispatcher)

        let pakoSys = pakoBrain.systemPrompt()
        let mituSys = mituBrain.systemPrompt()
        let zorpSys = zorpBrain.systemPrompt()

        try XCTAssertContains(pakoSys, "0.40")
        try XCTAssertContains(mituSys, "0.05")
        try XCTAssertContains(zorpSys, "0.50")

        // 排序验证：mitu (0.05) < pako (0.40) < zorp (0.50)
        try XCTAssertLessThan(mitu.manifest.humor.jokeDensity, pako.manifest.humor.jokeDensity)
        try XCTAssertLessThan(pako.manifest.humor.jokeDensity, zorp.manifest.humor.jokeDensity)
    }

    // MARK: - action / audio lookup miss

    tests.add("Brain.testActionLookupMiss_returnsNil") { _ in
        // 直接用 Brain 内部的 resolveAction（通过 init 注入一个返回不存在 action 的 mock）
        // 简化方案：构造一个 fixture LLM，prompt 强制命中含不存在 action 的 fixture（用 minimal fixture）
        // 然后验 response.action == nil
        let profile = try loadPakoProfile()
        // 构造一个 mock LLM 直接返回 "jelly-bouncex"（不存在的 action）
        let bogusLLM = StaticLLM(raw: "{\"text\": \"hi\", \"expression\": \"happy\", \"action\": \"jelly-bouncex\", \"audio_catchphrase\": \"不存在的catchphrase\"}")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: bogusLLM, dispatcher: dispatcher)

        let response = try brain.respond(to: "anything")
        // text / expression 正常
        try XCTAssertEqual(response.text, "hi")
        try XCTAssertEqual(response.expression, .happy)
        // action / audio 解析失败 → nil
        try XCTAssertNil(response.action, "action name 'jelly-bouncex' not in profile → nil")
        try XCTAssertNil(response.audioCatchphrase, "audio text not in profile → nil")

        // dispatcher 仍然跑：expression 必传，action/audio nil
        try XCTAssertEqual(sink.expressionCalls, [.happy])
        try XCTAssertEqual(sink.actionCalls.count, 0)
        try XCTAssertEqual(sink.audioNilCount, 1, "audio sink should be called with nil when miss")
    }

    tests.add("Brain.testMinimalResponse_keepsCurrentState") { _ in
        // LLM 不返回 expression → brain 保持 currentState
        let profile = try loadPakoProfile()
        let minimalLLM = StaticLLM(raw: "{\"text\": \"哦。\"}")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: minimalLLM, dispatcher: dispatcher, initialState: .focus)

        let response = try brain.respond(to: "hi")
        try XCTAssertEqual(response.expression, .focus, "no expression from LLM → keep current state")
        try XCTAssertEqual(sink.expressionCalls, [.focus])
        try XCTAssertEqual(brain.currentState, .focus)
    }

    // MARK: - state + lastAction 跨多次 respond 维护

    tests.add("Brain.testStateAndLastActionMaintainAcrossResponds") { _ in
        let profile = try loadPakoProfile()
        let llm = try makeMockLLM(prefix: "pako-")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

        // 第 1 次 respond：走 comfort 路径 → happy + jelly-bounce
        let r1 = try brain.respond(to: "我累了")
        try XCTAssertEqual(r1.expression, .happy)
        try XCTAssertEqual(brain.currentState, .happy)
        try XCTAssertEqual(brain.lastAction, "jelly-bounce")

        // 第 2 次 respond：keyword 走 minimal（joke/celebrate/tired/comfort 都不命中"再见"）
        // 但 prompt 里的 lastAction 应该是 "jelly-bounce" 了
        let _ = try brain.respond(to: "再见 12345xyz")
        // currentState 可能因为轮转改了，但 lastAction 也应被维护
        try XCTAssertEqual(brain.respondCount, 2)

        // prompt 验证
        let sys = brain.systemPrompt()
        try XCTAssertContains(sys, "0.40")
    }

    // MARK: - LLMError 透传

    tests.add("Brain.testLLMError_throwsUp") { _ in
        let profile = try loadPakoProfile()
        let errorLLM = FailingLLM()
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: errorLLM, dispatcher: dispatcher)

        try XCTAssertThrowsError { _ = try brain.respond(to: "hi") }
    }

    tests.add("Brain.testMalformedResponse_throwsMalformedError") { _ in
        let profile = try loadPakoProfile()
        let badLLM = StaticLLM(raw: "not json")
        let sink = BrainTestSink()
        let dispatcher = ChannelDispatcher(sink: sink)
        let brain = Brain(profile: profile, llm: badLLM, dispatcher: dispatcher)

        do {
            _ = try brain.respond(to: "hi")
            try XCTAssertTrue(false, "should have thrown")
        } catch let err as LLMError {
            if case .malformedResponse = err {
                // expected
            } else {
                try XCTAssertTrue(false, "expected .malformedResponse, got \(err)")
            }
        }
    }
}

// MARK: - test helpers

/// 构造 mock LLM（从 prefix 命名的 fixture 里）
func makeMockLLM(prefix: String) throws -> MockLLM {
    let fs = try TestMockLLMLoader.loadAll(prefix: prefix)
    return MockLLM(fixtures: fs)
}

/// 静态 LLM：永远返回同一个 raw 字符串
final class StaticLLM: LLMProvider {
    let raw: String
    init(raw: String) { self.raw = raw }
    func complete(prompt: String) throws -> String { return raw }
}

/// 永远抛错的 LLM
final class FailingLLM: LLMProvider {
    func complete(prompt: String) throws -> String {
        throw LLMError.transportFailed(reason: "test")
    }
}

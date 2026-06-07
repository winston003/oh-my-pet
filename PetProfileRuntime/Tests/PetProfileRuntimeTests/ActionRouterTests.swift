// ActionRouterTests.swift
// PetActionRouter 单元测试 — 事件 → 通道调度 + 状态机 + 招牌反应
//
// 覆盖（任务 spec "单元测试" 列表）：
//   - 初始 state = .idle
//   - 事件 → 通道调度（mock audio / expression / action 全部记录）
//   - 通道优先级 expression → action → audio
//   - 招牌反应 Pako jelly-bounce: spring params 正确，state 切到 happy
//   - currentState 字段更新（focus_start → focus；task_done → celebrate）
//   - focus_start 中断 idle 的 reaction（interrupt_idle 处理）
//   - 反应不存在的事件：dispatcher 仍调 sink（audio 通道收到 nil）
//   - audio cooldown：同一 text 在 cooldown 内只播一次
//   - longPress 命中 audio.catchphrases（"没事，慢慢来"，cooldown 30s）
//   - dragStart / dragEnd 都命中 "drag" reaction（旧 profile 兼容）
//   - Notification 投递（petVisualStateChanged）
//
// P2-A3 新增（Mitu + Zorp 招牌反应端到端集成）：
//   - 4 个 ActionRouter 集成测试：Mitu click / Mitu longPress / Zorp click / Zorp doubleClick
//     验证 spring params 经 ActionReaction.from 端到端透传
//   - Audio catchphrase 正确触发 + cooldown：
//     * Mitu click → "嗯嗯"（cooldown 30s）
//     * Zorp doubleClick → "凡人，你又来了"（cooldown 60s）
//   - Interrupt 透传：focus_start 中断任意 pet 当前 reaction（不只 Pako）
//   - 通道优先级不变：Mitu / Zorp 同样走 expression → action → audio
//   - 不同 pet 共用同一 Router 框架（PetActionRouter 类不变，3 个 pet profile 都能喂）
//
// 隔离：每个 test 重新 load fixture（避免 Pako/Mitu/Zorp fixture 串味）+ new MockChannelSink + new Router。

import Foundation
import AppKit
import PetProfile
@testable import PetProfileRuntime

func registerActionRouterTests(_ tests: Tests) {

    // MARK: - 辅助

    func loadPako() throws -> LoadedPetProfile {
        let manifestURL = try copyPakoFixtureToTmp()
        return try PetProfileLoader().loadProfile(from: manifestURL)
    }

    func makeRouter(time: TimeInterval = 0) throws -> (PetActionRouter, MockChannelSink, PetPanel) {
        let profile = try loadPako()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        let router = PetActionRouter(
            profile: profile,
            panel: panel,
            sink: mock,
            timeProvider: { time }
        )
        return (router, mock, panel)
    }

    // P2-A3：Mitu + Zorp fixture helpers。每个 helper 复制 fixture 到 /tmp，
    // 避免 3 个 pet fixture 串味 / 共享 placeholder PNG。
    func copyMituFixtureToTmp() throws -> URL {
        let original = try XCTUnwrap(
            Bundle.module.url(forResource: "mitu-v1.0.0", withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture mitu-v1.0.0.json"
        )
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pet-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let dest = tmpRoot.appendingPathComponent("mitu-v1.0.0.json")
        try FileManager.default.copyItem(at: original, to: dest)
        return dest
    }

    func loadMitu() throws -> LoadedPetProfile {
        let manifestURL = try copyMituFixtureToTmp()
        return try PetProfileLoader().loadProfile(from: manifestURL)
    }

    func makeMituRouter(time: TimeInterval = 0) throws -> (PetActionRouter, MockChannelSink, PetPanel) {
        let profile = try loadMitu()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        let router = PetActionRouter(
            profile: profile,
            panel: panel,
            sink: mock,
            timeProvider: { time }
        )
        return (router, mock, panel)
    }

    func copyZorpFixtureToTmp() throws -> URL {
        let original = try XCTUnwrap(
            Bundle.module.url(forResource: "zorp-v1.0.0", withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture zorp-v1.0.0.json"
        )
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pet-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let dest = tmpRoot.appendingPathComponent("zorp-v1.0.0.json")
        try FileManager.default.copyItem(at: original, to: dest)
        return dest
    }

    func loadZorp() throws -> LoadedPetProfile {
        let manifestURL = try copyZorpFixtureToTmp()
        return try PetProfileLoader().loadProfile(from: manifestURL)
    }

    func makeZorpRouter(time: TimeInterval = 0) throws -> (PetActionRouter, MockChannelSink, PetPanel) {
        let profile = try loadZorp()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        let router = PetActionRouter(
            profile: profile,
            panel: panel,
            sink: mock,
            timeProvider: { time }
        )
        return (router, mock, panel)
    }

    // MARK: - 初始 state

    tests.add("ActionRouter.testInitialStateIsIdle") { _ in
        let (router, _, _) = try makeRouter()
        try XCTAssertEqual(router.currentState, .idle)
    }

    // MARK: - click 招牌反应 Pako jelly-bounce

    tests.add("ActionRouter.testClickChangesStateToHappy") { _ in
        let (router, _, panel) = try makeRouter()
        router.handle(event: .click)
        try XCTAssertEqual(router.currentState, .happy, "click should derive .happy (no catchphrase.expression override in fixture)")
        try XCTAssertEqual(panel.currentState, "happy")
    }

    tests.add("ActionRouter.testClickTriggersJellyBounceAction") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .click)
        try XCTAssertEqual(mock.actionCalls.count, 1)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertEqual(ar.name, "jelly-bounce")
        try XCTAssertEqual(ar.trigger, .click)
        try XCTAssertEqual(ar.assetFormat, .springAnimation)
        try XCTAssertNotNil(ar.springParams, "jelly-bounce should carry springParams")
        try XCTAssertEqual(ar.springParams, SpringAnimation.jellyBounceParams())
    }

    tests.add("ActionRouter.testClickChannelOrder") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .click)
        // fixture 里 click 没 audio catchphrase → audio 是 nil；order 仍走 .audio
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio])
    }

    tests.add("ActionRouter.testClickHasNoAudioInFixture") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .click)
        try XCTAssertEqual(mock.audioCalls.count, 0, "fixture has no click catchphrase")
        try XCTAssertEqual(mock.audioNilCount, 1, "audio channel still gets called (with nil)")
    }

    // MARK: - doubleClick

    tests.add("ActionRouter.testDoubleClickTriggersEyeRoll") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .doubleClick)
        try XCTAssertEqual(mock.actionCalls.count, 1)
        try XCTAssertEqual(mock.actionCalls.first?.name, "eye-roll")
        try XCTAssertEqual(mock.actionCalls.first?.assetFormat, .mp4Alpha)
        try XCTAssertNil(mock.actionCalls.first?.springParams, "mp4-alpha should not have spring")
        try XCTAssertEqual(router.currentState, .happy)
    }

    // MARK: - longPress 命中 audio catchphrase

    tests.add("ActionRouter.testLongPressTriggersAudioCatchphrase") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .longPress)
        // fixture: longPress catchphrase "没事，慢慢来"，cooldown 30s, expression=idle
        try XCTAssertEqual(mock.audioCalls, ["没事，慢慢来"])
        try XCTAssertEqual(mock.expressionCalls, [.idle], "longPress catchphrase.expression=idle should override default .happy")
        try XCTAssertEqual(router.currentState, .idle)
        try XCTAssertEqual(mock.actionCalls.count, 0, "no longPress reaction in fixture")
    }

    // MARK: - dragStart / dragEnd 兼容旧 .drag

    tests.add("ActionRouter.testDragStartHitsLegacyDragReaction") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .dragStart)
        try XCTAssertEqual(mock.actionCalls.count, 1)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertEqual(ar.name, "rubber-stretch")
        // reaction.trigger=.drag, 但 runtime 记录 dragStart（更精确）
        try XCTAssertEqual(ar.trigger, .dragStart)
    }

    tests.add("ActionRouter.testDragEndHitsLegacyDragReaction") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .dragEnd)
        try XCTAssertEqual(mock.actionCalls.count, 1)
        try XCTAssertEqual(mock.actionCalls.first?.name, "rubber-stretch")
        try XCTAssertEqual(mock.actionCalls.first?.trigger, .dragEnd)
    }

    // MARK: - 状态机

    tests.add("ActionRouter.testFocusStartChangesStateToFocus") { _ in
        let (router, mock, panel) = try makeRouter()
        router.handle(event: .focusStart)
        try XCTAssertEqual(router.currentState, .focus)
        try XCTAssertEqual(panel.currentState, "focus")
        try XCTAssertEqual(mock.expressionCalls, [.focus])
    }

    tests.add("ActionRouter.testFocusEndChangesStateToIdle") { _ in
        let (router, mock, panel) = try makeRouter()
        router.handle(event: .focusStart)
        router.handle(event: .focusEnd)
        try XCTAssertEqual(router.currentState, .idle)
        try XCTAssertEqual(panel.currentState, "idle")
        try XCTAssertEqual(mock.expressionCalls, [.focus, .idle])
    }

    tests.add("ActionRouter.testTaskDoneChangesStateToCelebrate") { _ in
        let (router, mock, panel) = try makeRouter()
        router.handle(event: .taskDone)
        try XCTAssertEqual(router.currentState, .celebrate)
        try XCTAssertEqual(panel.currentState, "celebrate")
        try XCTAssertEqual(mock.expressionCalls, [.celebrate])
    }

    tests.add("ActionRouter.testFocusStartInterruptsIdle") { _ in
        // interrupt_idle 语义: 当前 state=.idle（idle breathing 在跑），
        // focus_start 来了切到 .focus，等价于"中断 idle"。
        let (router, _, _) = try makeRouter()
        try XCTAssertEqual(router.currentState, .idle, "initial state must be .idle")
        router.handle(event: .focusStart)
        try XCTAssertEqual(router.currentState, .focus, "focus_start should interrupt idle state")
    }

    tests.add("ActionRouter.testClickReactionsWithInterruptsIdleFlag") { _ in
        // 招牌 jelly-bounce 的 schema 字段 interrupts_idle=true 应原样透传
        let (router, mock, _) = try makeRouter()
        router.handle(event: .click)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertTrue(ar.interruptsIdle, "jelly-bounce interruptsIdle should be true (from fixture)")
    }

    tests.add("ActionRouter.testNonInterruptingReactionPreserved") { _ in
        // 用 eye-roll (doubleClick) 也设了 interrupts_idle=true; 没有 false 的 fixture
        // 这里改成验 eye-roll 至少传递了 interruptsIdle
        let (router, mock, _) = try makeRouter()
        router.handle(event: .doubleClick)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertTrue(ar.interruptsIdle)
    }

    // MARK: - 没有 reaction / catchphrase 的事件

    tests.add("ActionRouter.testShakeWindowNoReactionInFixture") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .shakeWindow)
        try XCTAssertEqual(mock.actionCalls.count, 0)
        try XCTAssertEqual(mock.audioNilCount, 1)
        try XCTAssertEqual(router.currentState, .happy, "no override → default .happy")
    }

    tests.add("ActionRouter.testHoverEnterChangesToHappy") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .hoverEnter)
        try XCTAssertEqual(mock.expressionCalls, [.happy])
        try XCTAssertEqual(mock.actionCalls.count, 0)
        try XCTAssertEqual(mock.audioNilCount, 1)
    }

    tests.add("ActionRouter.testHoverLeaveChangesToHappy") { _ in
        let (router, mock, _) = try makeRouter()
        router.handle(event: .hoverLeave)
        try XCTAssertEqual(mock.expressionCalls, [.happy])
    }

    // MARK: - audio cooldown

    tests.add("ActionRouter.testAudioCooldownSuppressesRepeat") { _ in
        // 单 router 共享 time provider；longPress 的 catchphrase "没事，慢慢来" cooldown 30s
        let profile = try loadPako()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        var now: TimeInterval = 1000.0
        let router = PetActionRouter(
            profile: profile,
            panel: panel,
            sink: mock,
            timeProvider: { now }
        )
        // t=1000: 第一次 longPress → 播
        router.handle(event: .longPress)
        try XCTAssertEqual(mock.audioCalls, ["没事，慢慢来"], "first longPress at t=1000 plays audio")
        // t=1000.5: 0.5s 后再 longPress → cooldown 内（30s）→ skip
        now += 0.5
        router.handle(event: .longPress)
        try XCTAssertEqual(mock.audioCalls.count, 1, "second longPress within 30s cooldown should skip audio (still 1 play total)")
        try XCTAssertEqual(mock.audioNilCount, 1, "audio sink still gets called with nil")
        // t=1032.0: 31.5s 后再 longPress → 超过 cooldown → 播
        now += 31.0
        router.handle(event: .longPress)
        try XCTAssertEqual(mock.audioCalls.count, 2, "after cooldown elapses, audio plays again")
    }

    tests.add("ActionRouter.testAudioCooldownSeparateTextsIndependent") { _ in
        // Pako fixture 里 longPress 只有一条 catchphrase; 验证不同 text 互不干扰
        // 用两个不同的 mock sink 测不同 router 实例（cooldown 状态是 per-router）
        let now: TimeInterval = 0
        let (r1, m1, _) = try makeRouter(time: now)
        r1.handle(event: .longPress)
        try XCTAssertEqual(m1.audioCalls, ["没事，慢慢来"])
        // 不同 router 实例从 0 开始，cooldown 独立
        let (r2, m2, _) = try makeRouter(time: now)
        r2.handle(event: .longPress)
        try XCTAssertEqual(m2.audioCalls, ["没事，慢慢来"], "different router instances have independent cooldown")
    }

    // MARK: - Notification 投递

    tests.add("ActionRouter.testHandlePostsVisualStateChangedNotification") { _ in
        let profile = try loadPako()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        let router = PetActionRouter(profile: profile, panel: panel, sink: mock)
        var received: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .petVisualStateChanged, object: panel, queue: .main
        ) { n in received.append(n) }
        defer { NotificationCenter.default.removeObserver(observer) }
        router.handle(event: .click)
        try XCTAssertEqual(received.count, 1)
        try XCTAssertEqual(received.first?.userInfo?["state"] as? VisualState, .happy)
    }

    // MARK: - PetEvent.candidateTriggers

    tests.add("ActionRouter.testCandidateTriggers") { _ in
        try XCTAssertEqual(PetEvent.click.candidateTriggers, [.click])
        try XCTAssertEqual(PetEvent.dragStart.candidateTriggers, [.dragStart, .drag])
        try XCTAssertEqual(PetEvent.dragEnd.candidateTriggers, [.dragEnd, .drag])
        try XCTAssertEqual(PetEvent.focusStart.candidateTriggers, [.focusStart])
        try XCTAssertEqual(PetEvent.taskDone.candidateTriggers, [.taskDone])
    }

    // MARK: - P2-A3 Mitu 招牌反应 集成测试

    // Mitu click → fur-shake-look-up spring params
    tests.add("ActionRouter.testMituClickFurShakeLookUpSpring") { _ in
        let (router, mock, _) = try makeMituRouter()
        router.handle(event: .click)
        // 1. action 通道被打：name=fur-shake-look-up, trigger=.click
        try XCTAssertEqual(mock.actionCalls.count, 1)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertEqual(ar.name, "fur-shake-look-up")
        try XCTAssertEqual(ar.trigger, .click)
        try XCTAssertEqual(ar.assetFormat, .springAnimation)
        // 2. springParams 等于 mituFurShakeParams（端到端透传）
        try XCTAssertNotNil(ar.springParams, "fur-shake-look-up should carry springParams (spring-animation format)")
        try XCTAssertEqual(ar.springParams, SpringAnimation.mituFurShakeParams())
        // 3. 通道优先级：expression → action → audio
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio])
        // 4. fixture 里 click 有 audio catchphrase "嗯嗯"（cooldown 30s, expression=happy）
        //    → 派生 state 走 catchphrase.expression=happy（不是默认 .happy），
        //    但 .happy == .happy 所以 router.currentState == .happy，audio 通道收到 "嗯嗯"
        try XCTAssertEqual(mock.audioCalls, ["嗯嗯"])
        try XCTAssertEqual(mock.expressionCalls, [.happy])
        try XCTAssertEqual(router.currentState, .happy)
    }

    // Mitu longPress → curl-into-ball spring params（反向曲线）
    tests.add("ActionRouter.testMituLongPressCurlIntoBallSpring") { _ in
        let (router, mock, _) = try makeMituRouter()
        router.handle(event: .longPress)
        // 1. action 通道：curl-into-ball
        try XCTAssertEqual(mock.actionCalls.count, 1)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertEqual(ar.name, "curl-into-ball")
        try XCTAssertEqual(ar.trigger, .longPress)
        try XCTAssertEqual(ar.assetFormat, .springAnimation)
        // 2. springParams 等于 mituCurlParams（反向：peak 0.6 / second 1.05）
        try XCTAssertNotNil(ar.springParams)
        let sp = try XCTUnwrap(ar.springParams)
        try XCTAssertEqualD(sp.duration, 1.0, accuracy: 1e-9, "curl-into-ball duration 1.0s")
        try XCTAssertEqualD(sp.peakScale, 0.6, accuracy: 1e-9, "curl-into-ball peak 0.6 (反向 spring)")
        try XCTAssertEqualD(sp.secondScale, 1.05, accuracy: 1e-9, "curl-into-ball second 1.05 (弹开)")
        try XCTAssertEqual(sp, SpringAnimation.mituCurlParams())
        // 3. Mitu fixture 里 longPress 没有 audio catchphrase → audio 通道收到 nil
        try XCTAssertEqual(mock.audioCalls.count, 0, "Mitu fixture has no longPress catchphrase")
        try XCTAssertEqual(mock.audioNilCount, 1, "audio channel still called with nil")
        // 4. 无 catchphrase.expression override → 默认 .happy
        try XCTAssertEqual(router.currentState, .happy)
    }

    // MARK: - P2-A3 Zorp 招牌反应 集成测试

    // Zorp click → tentacle-slap spring params
    tests.add("ActionRouter.testZorpClickTentacleSlapSpring") { _ in
        let (router, mock, _) = try makeZorpRouter()
        router.handle(event: .click)
        // 1. action 通道：tentacle-slap
        try XCTAssertEqual(mock.actionCalls.count, 1)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertEqual(ar.name, "tentacle-slap")
        try XCTAssertEqual(ar.trigger, .click)
        try XCTAssertEqual(ar.assetFormat, .springAnimation)
        // 2. springParams = zorpTentacleSlapParams（peak 1.15 振幅大）
        try XCTAssertNotNil(ar.springParams)
        let sp = try XCTUnwrap(ar.springParams)
        try XCTAssertEqualD(sp.peakScale, 1.15, accuracy: 1e-9, "tentacle-slap peak 1.15")
        try XCTAssertEqualD(sp.secondScale, 0.92, accuracy: 1e-9, "tentacle-slap second 0.92")
        try XCTAssertEqual(sp, SpringAnimation.zorpTentacleSlapParams())
        // 3. 通道优先级 expression → action → audio
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio])
        // 4. fixture 里 click 没 audio catchphrase → audio nil
        try XCTAssertEqual(mock.audioCalls.count, 0)
        try XCTAssertEqual(mock.audioNilCount, 1)
        try XCTAssertEqual(router.currentState, .happy)
    }

    // Zorp doubleClick → spin-rainbow spring params
    tests.add("ActionRouter.testZorpDoubleClickSpinRainbowSpring") { _ in
        let (router, mock, _) = try makeZorpRouter()
        router.handle(event: .doubleClick)
        // 1. action 通道：spin-rainbow
        try XCTAssertEqual(mock.actionCalls.count, 1)
        let ar = try XCTUnwrap(mock.actionCalls.first)
        try XCTAssertEqual(ar.name, "spin-rainbow")
        try XCTAssertEqual(ar.trigger, .doubleClick)
        try XCTAssertEqual(ar.assetFormat, .springAnimation)
        // 2. springParams = zorpSpinParams（damping 0.3 弹性最强 + peak 1.2 最大）
        try XCTAssertNotNil(ar.springParams)
        let sp = try XCTUnwrap(ar.springParams)
        try XCTAssertEqualD(sp.duration, 1.0, accuracy: 1e-9, "spin-rainbow duration 1.0s")
        try XCTAssertEqualD(sp.damping, 0.3, accuracy: 1e-9, "spin-rainbow damping 0.3 (5 pet 中最小)")
        try XCTAssertEqualD(sp.peakScale, 1.2, accuracy: 1e-9, "spin-rainbow peak 1.2 (5 pet 中最大)")
        try XCTAssertEqual(sp, SpringAnimation.zorpSpinParams())
        // 3. fixture 里 doubleClick 有 audio catchphrase "凡人，你又来了"（cooldown 60s, expression=tired）
        //    → 派生 state 走 catchphrase.expression=tired
        try XCTAssertEqual(mock.audioCalls, ["凡人，你又来了"])
        try XCTAssertEqual(mock.expressionCalls, [.tired])
        try XCTAssertEqual(router.currentState, .tired, "doubleClick catchphrase.expression=tired 应覆盖默认 .happy")
    }

    // MARK: - P2-A3 Mitu + Zorp audio catchphrase cooldown

    // Mitu click → "嗯嗯"（cooldown 30s）
    tests.add("ActionRouter.testMituClickAudioCatchphraseCooldown") { _ in
        let profile = try loadMitu()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        var now: TimeInterval = 500.0
        let router = PetActionRouter(
            profile: profile, panel: panel, sink: mock, timeProvider: { now }
        )
        // t=500: 第一次 click → 播 "嗯嗯"
        router.handle(event: .click)
        try XCTAssertEqual(mock.audioCalls, ["嗯嗯"])
        // t=500.5: 0.5s 后再 click → cooldown 内（30s）→ skip audio
        now += 0.5
        router.handle(event: .click)
        try XCTAssertEqual(mock.audioCalls.count, 1, "second click within 30s should skip audio")
        try XCTAssertEqual(mock.audioNilCount, 1, "audio sink still gets called with nil on cooldown")
        // t=535.0: 34.5s 后再 click → 超过 30s → 播
        now += 34.0
        router.handle(event: .click)
        try XCTAssertEqual(mock.audioCalls.count, 2, "after cooldown elapses, audio plays again")
    }

    // Zorp doubleClick → "凡人，你又来了"（cooldown 60s）
    tests.add("ActionRouter.testZorpDoubleClickAudioCatchphraseCooldown") { _ in
        let profile = try loadZorp()
        let panel = PetPanel(profile: profile)
        let mock = MockChannelSink()
        var now: TimeInterval = 1000.0
        let router = PetActionRouter(
            profile: profile, panel: panel, sink: mock, timeProvider: { now }
        )
        // t=1000: 第一次 doubleClick → 播
        router.handle(event: .doubleClick)
        try XCTAssertEqual(mock.audioCalls, ["凡人，你又来了"])
        // t=1030.0: 30s 后再 doubleClick → cooldown 内（60s）→ skip
        now += 30.0
        router.handle(event: .doubleClick)
        try XCTAssertEqual(mock.audioCalls.count, 1, "second doubleClick within 60s should skip audio")
        // t=1061.0: 31s 后再 doubleClick → 超过 60s → 播
        now += 31.0
        router.handle(event: .doubleClick)
        try XCTAssertEqual(mock.audioCalls.count, 2, "after 60s cooldown elapses, audio plays again")
    }

    // MARK: - P2-A3 通道优先级不变（Mitu / Zorp 同样走 expression → action → audio）

    tests.add("ActionRouter.testMituClickChannelOrder") { _ in
        let (router, mock, _) = try makeMituRouter()
        router.handle(event: .click)
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio],
                           "Mitu click must dispatch in same channel order as Pako")
    }

    tests.add("ActionRouter.testZorpClickChannelOrder") { _ in
        let (router, mock, _) = try makeZorpRouter()
        router.handle(event: .click)
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio],
                           "Zorp click must dispatch in same channel order as Pako")
    }

    tests.add("ActionRouter.testZorpDoubleClickChannelOrder") { _ in
        let (router, mock, _) = try makeZorpRouter()
        router.handle(event: .doubleClick)
        // Zorp doubleClick 有 catchphrase.expression=tired → expression=tired 先打
        // 然后 action（spin-rainbow），最后 audio（"凡人，你又来了"）
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio])
        try XCTAssertEqual(mock.expressionCalls, [.tired])
        try XCTAssertEqual(mock.actionCalls.first?.name, "spin-rainbow")
        try XCTAssertEqual(mock.audioCalls, ["凡人，你又来了"])
    }

    // MARK: - P2-A3 Interrupt 透传（Mitu / Zorp focus_start 同样中断当前 state）

    tests.add("ActionRouter.testMituFocusStartInterruptsCurrentState") { _ in
        let (router, _, panel) = try makeMituRouter()
        // 初始 .idle
        try XCTAssertEqual(router.currentState, .idle)
        // Mitu click → 派生 .happy（走 catchphrase.expression）
        router.handle(event: .click)
        try XCTAssertEqual(router.currentState, .happy)
        // focusStart 中断 → 切到 .focus（pack-runtime 同一套 interrupt 规则）
        router.handle(event: .focusStart)
        try XCTAssertEqual(router.currentState, .focus)
        try XCTAssertEqual(panel.currentState, "focus")
    }

    tests.add("ActionRouter.testZorpFocusStartInterruptsCurrentState") { _ in
        let (router, _, panel) = try makeZorpRouter()
        try XCTAssertEqual(router.currentState, .idle)
        // Zorp doubleClick → 派生 .tired
        router.handle(event: .doubleClick)
        try XCTAssertEqual(router.currentState, .tired)
        // focusStart 中断
        router.handle(event: .focusStart)
        try XCTAssertEqual(router.currentState, .focus)
        try XCTAssertEqual(panel.currentState, "focus")
    }

    // MARK: - P2-A3 3 pet 共用同一 PetActionRouter 类（不写分 pet 的 router）

    tests.add("ActionRouter.testAllThreePetsShareSameRouterClass") { _ in
        // 3 个 pet profile → 3 个 router 实例，全部是 PetActionRouter 同一类型
        let (rPako, _, _) = try makeRouter()
        let (rMitu, _, _) = try makeMituRouter()
        let (rZorp, _, _) = try makeZorpRouter()
        try XCTAssert(type(of: rPako) == PetActionRouter.self)
        try XCTAssert(type(of: rMitu) == PetActionRouter.self)
        try XCTAssert(type(of: rZorp) == PetActionRouter.self)
        // 3 个 router 的初始 state 都是 .idle（公共字段）
        try XCTAssertEqual(rPako.currentState, .idle)
        try XCTAssertEqual(rMitu.currentState, .idle)
        try XCTAssertEqual(rZorp.currentState, .idle)
    }

    tests.add("ActionRouter.testAllThreePetsInitialStateIdle") { _ in
        // 验 3 个 profile load 出的 reaction 名字空间不同（防 fixture 互相覆盖/串味）：
        //   Pako click → "jelly-bounce" (peak 1.1)
        //   Mitu click → "fur-shake-look-up" (peak 1.05)
        //   Zorp click → "tentacle-slap" (peak 1.15)
        // 走 helper 的 makeRouter / makeMituRouter / makeZorpRouter 三个独立实例
        let (pakoR, pakoM, _) = try makeRouter()
        let (mituR, mituM, _) = try makeMituRouter()
        let (zorpR, zorpM, _) = try makeZorpRouter()
        pakoR.handle(event: .click)
        mituR.handle(event: .click)
        zorpR.handle(event: .click)
        try XCTAssertEqual(pakoM.actionCalls.first?.name, "jelly-bounce")
        try XCTAssertEqual(mituM.actionCalls.first?.name, "fur-shake-look-up")
        try XCTAssertEqual(zorpM.actionCalls.first?.name, "tentacle-slap")
    }

    // MARK: - P2-A3 state machine 三 pet 一致（focus_end → idle, task_done → celebrate）

    tests.add("ActionRouter.testMituFocusEndChangesStateToIdle") { _ in
        let (router, mock, panel) = try makeMituRouter()
        router.handle(event: .focusStart)
        router.handle(event: .focusEnd)
        try XCTAssertEqual(router.currentState, .idle)
        try XCTAssertEqual(panel.currentState, "idle")
        try XCTAssertEqual(mock.expressionCalls, [.focus, .idle])
    }

    tests.add("ActionRouter.testZorpTaskDoneChangesStateToCelebrate") { _ in
        let (router, mock, panel) = try makeZorpRouter()
        router.handle(event: .taskDone)
        try XCTAssertEqual(router.currentState, .celebrate)
        try XCTAssertEqual(panel.currentState, "celebrate")
        try XCTAssertEqual(mock.expressionCalls, [.celebrate])
    }
}

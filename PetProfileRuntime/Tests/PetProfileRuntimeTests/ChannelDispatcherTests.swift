// ChannelDispatcherTests.swift
// ChannelSink / ChannelDispatcher / ActionReaction / AudioCatchphrase 单元测试
//
// 覆盖（任务 spec "通道优先级 / 通道调度"）：
//   - MockChannelSink 基础记录
//   - ChannelDispatcher 强制 expression → action → audio 顺序
//   - 通道独立跳过：action=nil / audio=nil 时只调存在的通道
//   - audio 即使为 nil 也调 sink（让 sink 知道"这一拍没口头禅"）
//   - ActionReaction.from(_:withTrigger:) 包装正确：trigger 覆盖、spring 查表
//   - AudioCatchphrase.from(_:) 默认 cooldown 30s
//   - ChannelKind 优先级排序
//   - PetPanelChannelSink 投递 notification（用 .petActionPlayed / .petAudioPlayed）
//
// 隔离：使用 MockChannelSink（不需要 fixture）；PetPanel 那个 test 走 fixture。

import Foundation
import AppKit
import PetProfile
@testable import PetProfileRuntime

func registerChannelDispatcherTests(_ tests: Tests) {

    // MARK: - MockChannelSink

    tests.add("ChannelSink.testMockRecordsAllCalls") { _ in
        let mock = MockChannelSink()
        mock.playExpression(.happy)
        mock.playAction(ActionReaction(name: "x", trigger: .click, durationMs: 100, assetFormat: .springAnimation, interruptsIdle: true, cooldownMs: 0, springParams: nil))
        mock.playAudio(AudioCatchphrase(text: "hi", trigger: .click, cooldownSeconds: 30, expression: nil))
        try XCTAssertEqual(mock.expressionCalls, [.happy])
        try XCTAssertEqual(mock.actionCalls.count, 1)
        try XCTAssertEqual(mock.audioCalls, ["hi"])
    }

    tests.add("ChannelSink.testMockReset") { _ in
        let mock = MockChannelSink()
        mock.playExpression(.focus)
        mock.reset()
        try XCTAssertEqual(mock.expressionCalls.count, 0)
        try XCTAssertEqual(mock.actionCalls.count, 0)
        try XCTAssertEqual(mock.audioCalls.count, 0)
        try XCTAssertEqual(mock.audioNilCount, 0)
    }

    // MARK: - ChannelKind priority

    tests.add("ChannelSink.testChannelKindPriority") { _ in
        // 顺序：expression(0) < action(1) < audio(2)
        try XCTAssertLessThan(ChannelKind.expression, ChannelKind.action)
        try XCTAssertLessThan(ChannelKind.action, ChannelKind.audio)
        try XCTAssertLessThan(ChannelKind.expression, ChannelKind.audio)
        try XCTAssertEqual(ChannelKind.allCases, [.expression, .action, .audio])
    }

    // MARK: - ChannelDispatcher ordering

    tests.add("ChannelDispatcher.testExpressionActionAudioOrder") { _ in
        let mock = MockChannelSink()
        let dispatcher = ChannelDispatcher(sink: mock)
        let reaction = ActionReaction(
            name: "jelly-bounce", trigger: .click, durationMs: 400,
            assetFormat: .springAnimation, interruptsIdle: true, cooldownMs: 500,
            springParams: SpringAnimation.jellyBounceParams()
        )
        let cp = AudioCatchphrase(text: "嘛", trigger: .click, cooldownSeconds: 30, expression: "happy")
        dispatcher.dispatch(expression: .happy, action: reaction, audio: cp)
        try XCTAssertEqual(mock.lastOrder, [.expression, .action, .audio])
    }

    tests.add("ChannelDispatcher.testNilActionSkipsActionChannel") { _ in
        let mock = MockChannelSink()
        let dispatcher = ChannelDispatcher(sink: mock)
        dispatcher.dispatch(expression: .focus, action: nil, audio: nil)
        try XCTAssertEqual(mock.lastOrder, [.expression, .audio])
        try XCTAssertEqual(mock.actionCalls.count, 0)
        try XCTAssertEqual(mock.expressionCalls, [.focus])
    }

    tests.add("ChannelDispatcher.testNilAudioStillCallsSink") { _ in
        // audio=nil 也调 sink.playAudio(nil)，让 sink 知道"这一拍没口头禅"
        // 默认 PanelChannelSink 在 nil 时 skip；MockChannelSink 计入 audioNilCount
        let mock = MockChannelSink()
        let dispatcher = ChannelDispatcher(sink: mock)
        dispatcher.dispatch(expression: .idle, action: nil, audio: nil)
        try XCTAssertEqual(mock.audioNilCount, 1, "audio sink should be called even with nil")
    }

    tests.add("ChannelDispatcher.testOnlyExpression") { _ in
        let mock = MockChannelSink()
        let dispatcher = ChannelDispatcher(sink: mock)
        dispatcher.dispatch(expression: .tired, action: nil, audio: nil)
        try XCTAssertEqual(mock.expressionCalls, [.tired])
        try XCTAssertEqual(mock.actionCalls.count, 0)
        try XCTAssertEqual(mock.audioCalls.count, 0)
    }

    tests.add("ChannelDispatcher.testOnlyAction") { _ in
        let mock = MockChannelSink()
        let dispatcher = ChannelDispatcher(sink: mock)
        let r = ActionReaction(name: "x", trigger: .click, durationMs: 100, assetFormat: nil, interruptsIdle: true, cooldownMs: 0, springParams: nil)
        dispatcher.dispatch(expression: .happy, action: r, audio: nil)
        try XCTAssertEqual(mock.actionCalls.count, 1)
        try XCTAssertEqual(mock.actionCalls.first?.name, "x")
    }

    tests.add("ChannelDispatcher.testCustomOrderingRespected") { _ in
        // 自定义 ordering: audio 先于 action（用于 "audio 提示 + action 动画" 场景）
        let mock = MockChannelSink()
        let dispatcher = ChannelDispatcher(sink: mock, ordering: [.expression, .audio, .action])
        let r = ActionReaction(name: "x", trigger: .click, durationMs: 100, assetFormat: nil, interruptsIdle: true, cooldownMs: 0, springParams: nil)
        let cp = AudioCatchphrase(text: "t", trigger: .click, cooldownSeconds: 30, expression: nil)
        dispatcher.dispatch(expression: .happy, action: r, audio: cp)
        try XCTAssertEqual(mock.lastOrder, [.expression, .audio, .action])
    }

    // MARK: - ActionReaction.from

    tests.add("ActionReaction.testFromSpringAnimationFillsSpringParams") { _ in
        // 构造一个 spring-animation 的 Reaction
        let r = Reaction(
            trigger: .click, name: "jelly-bounce", durationMs: 400,
            assetPath: "x.apng", assetFormat: .springAnimation,
            interruptsIdle: true, cooldownMs: 500
        )
        let ar = ActionReaction.from(r, withTrigger: .click)
        try XCTAssertEqual(ar.name, "jelly-bounce")
        try XCTAssertEqual(ar.trigger, .click)
        try XCTAssertEqual(ar.durationMs, 400)
        try XCTAssertEqual(ar.assetFormat, .springAnimation)
        try XCTAssertTrue(ar.interruptsIdle)
        try XCTAssertEqual(ar.cooldownMs, 500)
        try XCTAssertNotNil(ar.springParams)
        try XCTAssertEqual(ar.springParams, SpringAnimation.jellyBounceParams())
    }

    tests.add("ActionReaction.testFromNonSpringLeavesSpringParamsNil") { _ in
        let r = Reaction(
            trigger: .doubleClick, name: "eye-roll", durationMs: 800,
            assetPath: "x.mp4", assetFormat: .mp4Alpha,
            interruptsIdle: true, cooldownMs: 1000
        )
        let ar = ActionReaction.from(r, withTrigger: .doubleClick)
        try XCTAssertNil(ar.springParams)
        try XCTAssertFalse(ar.hasSpring)
    }

    tests.add("ActionReaction.testFromUnknownSpringNameFallsBackToDefault") { _ in
        // 假设未来出现一个新的 spring-animation reaction 但 runtime 表里没有
        let r = Reaction(
            trigger: .click, name: "mystery-spring", durationMs: 300,
            assetPath: nil, assetFormat: .springAnimation,
            interruptsIdle: true, cooldownMs: 500
        )
        let ar = ActionReaction.from(r, withTrigger: .click)
        try XCTAssertNotNil(ar.springParams, "fallback should fill defaultSpringParams")
        try XCTAssertEqual(ar.springParams, SpringAnimation.defaultSpringParams())
    }

    tests.add("ActionReaction.testFromOverridesTrigger") { _ in
        // 关键路径: dragStart 命中 .drag reaction 时，runtime 端记录 dragStart
        let r = Reaction(
            trigger: .drag, name: "rubber-stretch", durationMs: 600,
            assetPath: "x.mp4", assetFormat: .mp4Alpha,
            interruptsIdle: true, cooldownMs: 500
        )
        let arFromDragStart = ActionReaction.from(r, withTrigger: .dragStart)
        let arFromDragEnd = ActionReaction.from(r, withTrigger: .dragEnd)
        try XCTAssertEqual(arFromDragStart.trigger, .dragStart)
        try XCTAssertEqual(arFromDragEnd.trigger, .dragEnd)
    }

    // MARK: - AudioCatchphrase.from

    tests.add("AudioCatchphrase.testFromPassesThrough") { _ in
        let cp = Catchphrase(text: "嘛", trigger: .longPress, cooldownSeconds: 30, expression: "idle")
        let acp = AudioCatchphrase.from(cp)
        try XCTAssertEqual(acp.text, "嘛")
        try XCTAssertEqual(acp.trigger, .longPress)
        try XCTAssertEqualD(acp.cooldownSeconds, 30.0)
        try XCTAssertEqual(acp.expression, "idle")
    }

    tests.add("AudioCatchphrase.testFromDefaultsCooldown30") { _ in
        let cp = Catchphrase(text: "x", trigger: .aiReply, cooldownSeconds: nil, expression: nil)
        let acp = AudioCatchphrase.from(cp)
        try XCTAssertEqualD(acp.cooldownSeconds, 30.0, "missing cooldown defaults to 30s")
    }

    // MARK: - PanelChannelSink 投递 notification

    tests.add("PanelChannelSink.testPlayExpressionUpdatesPanel") { _ in
        let p = try loadPakoPanel()
        let sink = PanelChannelSink(panel: p)
        sink.playExpression(.focus)
        try XCTAssertEqual(p.currentState, "focus", "PanelChannelSink.playExpression should update panel.currentState via setVisualState")
        try XCTAssertEqual(p.visualState, .focus)
    }

    tests.add("PanelChannelSink.testPlayExpressionPostsNotification") { _ in
        let p = try loadPakoPanel()
        let sink = PanelChannelSink(panel: p)
        var received: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .petVisualStateChanged, object: p, queue: .main
        ) { n in received.append(n) }
        defer { NotificationCenter.default.removeObserver(observer) }
        sink.playExpression(.happy)
        try XCTAssertEqual(received.count, 1)
        try XCTAssertEqual(received.first?.userInfo?["state"] as? VisualState, .happy)
    }

    tests.add("PanelChannelSink.testPlayActionPostsNotification") { _ in
        let p = try loadPakoPanel()
        let sink = PanelChannelSink(panel: p)
        var received: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .petActionPlayed, object: p, queue: .main
        ) { n in received.append(n) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let r = ActionReaction(name: "jelly-bounce", trigger: .click, durationMs: 400, assetFormat: .springAnimation, interruptsIdle: true, cooldownMs: 500, springParams: SpringAnimation.jellyBounceParams())
        sink.playAction(r)
        try XCTAssertEqual(received.count, 1)
        let unpacked = try XCTUnwrap(received.first?.userInfo?["reaction"] as? ActionReaction)
        try XCTAssertEqual(unpacked.name, "jelly-bounce")
    }

    tests.add("PanelChannelSink.testPlayAudioPostsNotificationWithCatchphrase") { _ in
        let p = try loadPakoPanel()
        let sink = PanelChannelSink(panel: p)
        var received: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .petAudioPlayed, object: p, queue: .main
        ) { n in received.append(n) }
        defer { NotificationCenter.default.removeObserver(observer) }
        let cp = AudioCatchphrase(text: "嘛", trigger: .random, cooldownSeconds: 60, expression: "happy")
        sink.playAudio(cp)
        try XCTAssertEqual(received.count, 1)
        let unpacked = try XCTUnwrap(received.first?.userInfo?["catchphrase"] as? AudioCatchphrase)
        try XCTAssertEqual(unpacked.text, "嘛")
    }

    tests.add("PanelChannelSink.testPlayAudioNilPostsNotificationToo") { _ in
        let p = try loadPakoPanel()
        let sink = PanelChannelSink(panel: p)
        var received: [Notification] = []
        let observer = NotificationCenter.default.addObserver(
            forName: .petAudioPlayed, object: p, queue: .main
        ) { n in received.append(n) }
        defer { NotificationCenter.default.removeObserver(observer) }
        sink.playAudio(nil)
        try XCTAssertEqual(received.count, 1, "even nil audio posts a notification (so observers know 'no catchphrase')")
    }
}

// MARK: - test helper

/// 用 Pako fixture 加载一个 PetPanel（多个 ChannelDispatcher test 共用）
func loadPakoPanel() throws -> PetPanel {
    let manifestURL = try copyPakoFixtureToTmp()
    let p = try PetProfileLoader().loadProfile(from: manifestURL)
    return PetPanel(profile: p)
}

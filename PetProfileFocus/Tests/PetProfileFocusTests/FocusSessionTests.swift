// FocusSessionTests.swift
// FocusSession 单元测试 — 状态机 + 时间统计 + 跟 PetActionRouter 集成
//
// 覆盖（任务 spec "单元测试" 列表）：
//   - 初始 state = .idle
//   - start() → .focusing + router.handle(.focusStart)
//   - pause() → .paused + totalSeconds 累加
//   - resume() → .focusing（继续计时）
//   - complete() → .completed + 写 focus memory + router.handle(.focusEnd + .taskDone)
//   - abandon() → .idle + router.handle(.focusEnd)
//   - 非法 transition → throw
//   - 累计 todayFocusSeconds / streak
//   - clock 注入：用确定性时间控制总时长
//   - memory write 失败时抛 .memoryWriteFailed
//   - 跨 session 累计 lifetimeTotalSeconds
//
import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
@testable import PetProfileFocus

// MARK: - MockClock

/// 可注入时钟（closure-based）；测试用确定性时间。
final class MockClock {
    private(set) var now: Date
    init(initial: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.now = initial
    }
    func nowProvider() -> Date { now }
    func advance(_ seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

// MARK: - 注册

func registerFocusSessionTests(_ tests: Tests) {

    // 辅助：构造 tmp memory root + tmp pet root + PetActionRouter
    func makeFixtures() throws -> (URL, URL, MockClock, MemoryStore, LoadedPetProfile, PetActionRouter) {
        let memRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-mem-\(UUID().uuidString)", isDirectory: true)
        let petRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-pet-\(UUID().uuidString)", isDirectory: true)
        let memStore = MemoryStore(root: memRoot)
        let clock = MockClock()

        // 复制 Pako fixture 到 tmp，避免占位 PNG 串味
        let original = try XCTUnwrap(
            Bundle.module.url(forResource: "pako-v1.0.0", withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture pako-v1.0.0.json"
        )
        let tmpProfileRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("focus-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpProfileRoot, withIntermediateDirectories: true)
        let dest = tmpProfileRoot.appendingPathComponent("pako-v1.0.0.json")
        try FileManager.default.copyItem(at: original, to: dest)

        let profile = try PetProfileLoader().loadProfile(from: dest)
        let panel = PetPanel(profile: profile)
        let router = PetActionRouter(profile: profile, panel: panel)
        _ = petRoot  // 不强求用；保留接口对齐
        return (memRoot, petRoot, clock, memStore, profile, router)
    }

    // MARK: - 初始 state

    tests.add("FocusSession.testInitialStateIsIdle") { _ in
        let session = FocusSession()
        try XCTAssertEqual(session.state, .idle)
        try XCTAssertNil(session.startedAt)
        try XCTAssertEqual(session.totalSeconds, 0)
        try XCTAssertEqual(session.completedCount, 0)
    }

    // MARK: - start / pause / resume / complete / abandon 全部 transition

    tests.add("FocusSession.testStartChangesToFocusing") { _ in
        let (_, _, _, mem, _, router) = try makeFixtures()
        let session = FocusSession(memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        try XCTAssertEqual(session.state, .focusing)
        try XCTAssertEqual(router.currentState, .focus, "router must be triggered with .focusStart")
        try XCTAssertNotNil(session.startedAt)
    }

    tests.add("FocusSession.testStartFromNonIdleThrows") { _ in
        let (_, _, _, mem, _, router) = try makeFixtures()
        let session = FocusSession(memoryStore: mem)
        session.router = router
        try session.start()
        // 第二次 start 必抛
        try XCTAssertThrowsError({ try session.start() }, "start while focusing must throw")
    }

    tests.add("FocusSession.testPauseChangesToPaused") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(60)
        try session.pause()
        try XCTAssertEqual(session.state, .paused)
        try XCTAssertEqual(session.totalSeconds, 60, "pause should accumulate 60s into totalSeconds")
    }

    tests.add("FocusSession.testPauseFromNonFocusingThrows") { _ in
        let session = FocusSession()
        try XCTAssertThrowsError({ try session.pause() }, "pause from .idle must throw")
    }

    tests.add("FocusSession.testResumeChangesToFocusing") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(30)
        try session.pause()
        clock.advance(15)  // paused 期间不计时
        try session.resume()
        try XCTAssertEqual(session.state, .focusing)
        // totalSeconds 还应是 30（pause 段不计）
        try XCTAssertEqual(session.totalSeconds, 30)
        // 再 advance 20s，pause/resume 后另一段
        clock.advance(20)
        try session.pause()
        try XCTAssertEqual(session.totalSeconds, 50, "two focusing segments: 30 + 20 = 50")
    }

    tests.add("FocusSession.testResumeFromNonPausedThrows") { _ in
        let session = FocusSession()
        try XCTAssertThrowsError({ try session.resume() }, "resume from .idle must throw")
    }

    tests.add("FocusSession.testCompleteWritesFocusMemoryAndChangesState") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(1500)  // 25 min
        let memory = try session.complete()
        try XCTAssertEqual(session.state, .completed)
        try XCTAssertEqual(memory.type, .focus)
        try XCTAssertEqual(memory.petID, "pet_test")
        try XCTAssertEqual(memory.durationSeconds, 1500)
        // router 收到 focusEnd + taskDone → 最终 state = celebrate
        try XCTAssertEqual(router.currentState, .celebrate)
        // 写到 disk
        let loaded = try mem.load(forPetID: "pet_test")
        try XCTAssertEqual(loaded.count, 1)
        try XCTAssertEqual(loaded.first?.type, .focus)
    }

    tests.add("FocusSession.testCompleteFromPausedWritesMemory") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(60)
        try session.pause()
        clock.advance(30)
        // complete from paused
        let memory = try session.complete()
        try XCTAssertEqual(session.state, .completed)
        try XCTAssertEqual(memory.durationSeconds, 60, "complete from paused: only first segment counts (60s)")
    }

    tests.add("FocusSession.testCompleteFromIdleThrows") { _ in
        let session = FocusSession()
        try XCTAssertThrowsError({ _ = try session.complete() }, "complete from .idle must throw")
    }

    tests.add("FocusSession.testAbandonResetsToIdle") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(45)
        try session.abandon()
        try XCTAssertEqual(session.state, .idle)
        try XCTAssertEqual(router.currentState, .idle, "abandon must trigger .focusEnd → idle")
        try XCTAssertEqual(session.totalSeconds, 0, "abandon resets totalSeconds")
        try XCTAssertEqual(session.completedCount, 0, "abandon doesn't count as completion")
        // 不应写 memory
        let loaded = try mem.load(forPetID: "pet_test")
        try XCTAssertEqual(loaded.count, 0, "abandon must not write any memory")
    }

    tests.add("FocusSession.testAbandonFromIdleThrows") { _ in
        let session = FocusSession()
        try XCTAssertThrowsError({ try session.abandon() }, "abandon from .idle must throw")
    }

    // MARK: - 时间统计

    tests.add("FocusSession.testLifetimeTotalAccumulatesAcrossSessions") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        // session 1: 30 min
        try session.start()
        clock.advance(1800)
        _ = try session.complete()
        session.reset()
        try XCTAssertEqual(session.lifetimeTotalSeconds, 1800)
        try XCTAssertEqual(session.completedCount, 1)
        // session 2: 45 min
        try session.start()
        clock.advance(2700)
        _ = try session.complete()
        session.reset()
        try XCTAssertEqual(session.lifetimeTotalSeconds, 4500, "1800 + 2700 = 4500")
        try XCTAssertEqual(session.completedCount, 2, "streak (simplified) = 2")
    }

    tests.add("FocusSession.testTodayFocusSecondsEqualsLifetime") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(900)
        _ = try session.complete()
        try XCTAssertEqual(session.todayFocusSeconds, 900)
        try XCTAssertEqual(session.streak, 1)
    }

    // MARK: - 跟 PetActionRouter 集成

    tests.add("FocusSession.testRouterReceivesFocusStartOnStart") { _ in
        let (_, _, _, mem, _, router) = try makeFixtures()
        let session = FocusSession(memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try XCTAssertEqual(router.currentState, .idle, "initial router state must be .idle")
        try session.start()
        try XCTAssertEqual(router.currentState, .focus, "router must receive .focusStart event")
    }

    tests.add("FocusSession.testRouterReceivesFocusEndAndTaskDoneOnComplete") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(60)
        _ = try session.complete()
        // router.handle(.focusEnd) 把 state 改回 .idle，
        // 然后 router.handle(.taskDone) 改到 .celebrate；
        // 最终 state = .celebrate
        try XCTAssertEqual(router.currentState, .celebrate)
    }

    tests.add("FocusSession.testNoRouterIsAllowed") { _ in
        // router = nil 时不 crash，仅 skip router.handle 调用
        let (_, _, clock, mem, _, _) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(60)
        let memory = try session.complete()
        try XCTAssertEqual(memory.durationSeconds, 60)
    }

    // MARK: - memory 写盘失败 → throw

    tests.add("FocusSession.testMemoryWriteFailureThrowsMemoryWriteFailed") { _ in
        // 用 readonly memory root 模拟写盘失败
        let memRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-mem-readonly-\(UUID().uuidString)", isDirectory: true)
        // 故意把 root 创成文件而非目录，让后续 write 失败
        try "x".write(to: memRoot, atomically: true, encoding: .utf8)
        let memStore = MemoryStore(root: memRoot)
        let session = FocusSession(memoryStore: memStore)
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        let memory: SharedMemory? = try? session.complete()
        // memory 写失败 → complete 抛 .memoryWriteFailed
        try XCTAssertNil(memory, "complete must throw when memory write fails")
        try XCTAssertEqual(session.state, .focusing, "state should not move to .completed when memory write fails")
    }

    // MARK: - 重置 + 多 cycle

    tests.add("FocusSession.testResetAfterCompleteAllowsRestart") { _ in
        let (_, _, clock, mem, _, router) = try makeFixtures()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: mem)
        session.router = router
        session.petID = "pet_test"
        session.petName = "TestPet"
        try session.start()
        clock.advance(60)
        _ = try session.complete()
        try XCTAssertEqual(session.state, .completed)
        session.reset()
        try XCTAssertEqual(session.state, .idle)
        try session.start()  // reset 后 start 必须可用
        try XCTAssertEqual(session.state, .focusing)
    }
}
// RecoveryTests.swift
// 失败恢复测试：损坏 state.json → 重置到 Stage 1
//
// 覆盖：
//   - load() 遇到损坏 JSON → stateFileCorrupted
//   - load() 遇到缺字段 → stateFileCorrupted（也走 reset 路径）
//   - 损坏 → 走 OnboardingState.reset() 拿 fresh + 文件被删
//   - reset() 后再 load → stateFileNotFound（caller 决定 fresh start）
//   - 模拟 OnboardingApp 启动：loadOrReset 模式
//   - OnboardingFlow.reset() 等同于 OnboardingState.reset()
//   - 阶段 fallback：每个 stage 都有 fallback（具体看 state machine 校验）
//

import Foundation
@testable import PetProfileOnboarding

func registerRecoveryTests(_ tests: Tests) {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-recovery-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - load 损坏 → corrupted

    tests.add("Recovery.testLoadGarbageThrowsCorrupted") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        try Data("not even close to json".utf8).write(to: url)
        do {
            _ = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch let err as OnboardingError {
            switch err {
            case .stateFileCorrupted: break
            default: throw TestFailure(name: "test", message: "expected .stateFileCorrupted, got \(err)")
            }
        }
    }

    tests.add("Recovery.testLoadTruncatedJSONThrowsCorrupted") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        try Data("{\"current_stage\": \"welcom".utf8).write(to: url)
        do {
            _ = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch let err as OnboardingError {
            switch err {
            case .stateFileCorrupted: break
            default: throw TestFailure(name: "test", message: "expected .stateFileCorrupted, got \(err)")
            }
        }
    }

    tests.add("Recovery.testLoadMissingFieldThrowsCorrupted") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        // 合法 JSON 但缺 current_stage（required 字段）
        try Data("{\"chosen_path\": \"generate\"}".utf8).write(to: url)
        do {
            _ = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch let err as OnboardingError {
            switch err {
            case .stateFileCorrupted: break
            default: throw TestFailure(name: "test", message: "expected .stateFileCorrupted, got \(err)")
            }
        }
    }

    // MARK: - 恢复路径：corrupted → reset → fresh

    tests.add("Recovery.testCorruptedThenResetReturnsFresh") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        try Data("garbage".utf8).write(to: url)

        // 模拟 OnboardingApp 启动时的 loadOrReset 模式
        var recovered: OnboardingState = OnboardingState()
        do {
            recovered = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected load to throw")
        } catch OnboardingError.stateFileCorrupted {
            // 失败恢复：reset 拿 fresh
            recovered = try OnboardingState.reset(to: url)
        }

        try XCTAssertEqual(recovered.currentStage, .welcome)
        try XCTAssertNil(recovered.chosenPath)
        // 文件被删
        try XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - load 不存在 → notFound（caller 走 fresh start）

    tests.add("Recovery.testLoadNotFoundResolvesToFresh") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var resolved: OnboardingState = OnboardingState()
        do {
            resolved = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch OnboardingError.stateFileNotFound {
            resolved = OnboardingState()  // fresh
        }
        try XCTAssertEqual(resolved.currentStage, .welcome)
    }

    // MARK: - OnboardingFlow.reset() 删除文件 + 重置 state

    tests.add("Recovery.testFlowResetDeletesFile") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState(currentStage: .launchPet, chosenPath: .generate)
        try s.save(to: url)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let flow = OnboardingFlow(initialState: s, storeURL: url)
        try flow.reset()
        try XCTAssertEqual(flow.state.currentStage, .welcome)
        try XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - 半完成 state：welcome 阶段 → corrupted → reset → 重新走

    tests.add("Recovery.testHalfwayThenCorruptedThenReset") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        // 模拟走到 voiceCreate 阶段时崩了
        var s = OnboardingState(
            currentStage: .voiceCreate,
            chosenPath: .generate,
            petProfilePath: URL(fileURLWithPath: "/tmp/pako.omppet/manifest.json"),
            byokProvider: "openai",
            byokKeychainRef: "ref-1"
        )
        try s.save(to: url)
        // 文件被外部破坏（比如异常断电）
        try Data("CORRUPTED".utf8).write(to: url)

        // 启动 OnboardingApp 走 loadOrReset
        do {
            _ = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch OnboardingError.stateFileCorrupted {
            let fresh = try OnboardingState.reset(to: url)
            try XCTAssertEqual(fresh.currentStage, .welcome)
            try XCTAssertNil(fresh.chosenPath)
            try XCTAssertNil(fresh.petProfilePath)
        }
    }

    // MARK: - 阶段 fallback：每个 stage 写盘失败 → state 不更新

    tests.add("Recovery.testSaveFailureDoesNotMutateState") { _ in
        // 写一个不可写的目录（root 路径）模拟 save 失败
        let badURL = URL(fileURLWithPath: "/this/path/should/not/exist/and/not/be/writable/state.json")
        // 注：Swift 写会抛错（不是 panic），所以我们这里验证：
        // 1. save 抛 .persistenceWriteFailed
        // 2. in-memory state 已被 try 之前 mutate 了（这是当前设计选择 — 失败前已 mutate）
        // 文档化这个 trade-off：caller 负责在 try 之前 snapshot / 之后 reload

        var s = OnboardingState(currentStage: .voiceCreate, chosenPath: .generate)
        try XCTAssertThrowsError {
            try s.save(to: badURL)
        }
        // state 已被 mutate（失败前），但没落盘 → caller reload 拿到旧
        try XCTAssertEqual(s.currentStage, .voiceCreate)
    }

    // MARK: - 完整周期：fresh → 跑完 → corrupted → reset

    tests.add("Recovery.testFullCycleFreshCorruptedReset") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)

        // 1. fresh
        var s = OnboardingState()
        try s.save(to: url)

        // 2. 跑完整个 A 路径
        let flow = OnboardingFlow(initialState: s)
        try flow.choose(path: .generate)
        try flow.saveByok(provider: "openai", keychainRef: "ref")
        try flow.next()
        try flow.saveProfile(at: URL(fileURLWithPath: "/tmp/p.omppet/manifest.json"))
        try flow.next()
        try flow.saveVoice(style: "warm-gentle", cloned: false)
        try flow.next()
        try flow.markLaunched()
        try XCTAssertEqual(flow.state.currentStage, .completed)

        // 3. 模拟文件损坏
        try Data("garbled".utf8).write(to: url)

        // 4. 启动恢复：loadOrReset
        var recovered: OnboardingState = OnboardingState()
        do {
            recovered = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch OnboardingError.stateFileCorrupted {
            recovered = try OnboardingState.reset(to: url)
        }

        // 5. 回到 Stage 1
        try XCTAssertEqual(recovered.currentStage, .welcome)
        try XCTAssertNil(recovered.chosenPath)
        try XCTAssertNil(recovered.petProfilePath)
        try XCTAssertNil(recovered.voiceStyle)
        try XCTAssertNil(recovered.byokProvider)
        try XCTAssertNil(recovered.launchTime)
    }
}

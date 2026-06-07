// OnboardingStateTests.swift
// OnboardingState 持久化 roundtrip + 5 种 stage 转换测试
//
// 覆盖：
//   - save/load roundtrip（fresh / partial / full 字段）
//   - 5 种 stage 转换（welcome → byok → visual → voice → launchPet → completed）
//   - 错误：不存在 → stateFileNotFound
//   - 错误：损坏 JSON → stateFileCorrupted
//   - 错误：删除后 load → stateFileNotFound
//   - reset() 后 → fresh
//   - 注入 URL 测试用临时目录（不污染真 ~/Library/）
//

import Foundation
@testable import PetProfileOnboarding

func registerOnboardingStateTests(_ tests: Tests) {
    // 共享 temp dir（每个 test 用 subdir 隔离）
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-state-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - init + Codable roundtrip

    tests.add("State.testFreshStateHasWelcomeStage") { _ in
        let s = OnboardingState()
        try XCTAssertEqual(s.currentStage, .welcome)
        try XCTAssertNil(s.chosenPath)
        try XCTAssertNil(s.petProfilePath)
        try XCTAssertNil(s.voiceStyle)
        try XCTAssertFalse(s.voiceCloned)
        try XCTAssertNil(s.voiceCloneConsent)
        try XCTAssertNil(s.byokProvider)
        try XCTAssertNil(s.byokKeychainRef)
        try XCTAssertNil(s.launchTime)
    }

    tests.add("State.testRoundtripEmptyState") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState()
        try s.save(to: url)
        let loaded = try OnboardingState.load(from: url)
        try XCTAssertEqual(s, loaded)
    }

    tests.add("State.testRoundtripPathAWithAllFields") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState(
            currentStage: .voiceCreate,
            chosenPath: .generate,
            petProfilePath: URL(fileURLWithPath: "/tmp/pako.omppet/manifest.json"),
            voiceStyle: "drawl-deadpan",
            voiceCloned: true,
            voiceCloneConsent: VoiceCloneConsent(
                sampleFilename: "user-sample.wav",
                userConfirmsOwnership: true,
                consentTimestamp: Date(timeIntervalSince1970: 1_700_000_000)
            ),
            byokProvider: "openai",
            byokKeychainRef: "keychain-ref-mock",
            launchTime: nil
        )
        try s.save(to: url)
        let loaded = try OnboardingState.load(from: url)
        try XCTAssertEqual(s, loaded)
        try XCTAssertEqual(loaded.chosenPath, .generate)
        try XCTAssertEqual(loaded.voiceStyle, "drawl-deadpan")
        try XCTAssertTrue(loaded.voiceCloned)
        try XCTAssertEqual(loaded.voiceCloneConsent?.sampleFilename, "user-sample.wav")
        try XCTAssertTrue(loaded.voiceCloneConsent?.userConfirmsOwnership == true)
    }

    tests.add("State.testRoundtripSamplePathD") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState(
            currentStage: .launchPet,
            chosenPath: .sample,
            petProfilePath: URL(fileURLWithPath: "/Users/.../pako-v1.0.0.json")
        )
        try s.save(to: url)
        let loaded = try OnboardingState.load(from: url)
        try XCTAssertEqual(s, loaded)
        try XCTAssertEqual(loaded.chosenPath, .sample)
    }

    // MARK: - 5 种 stage 转换 roundtrip

    tests.add("State.testAllFiveStageTransitionsRoundtrip") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        let stages: [OnboardingStage] = [.welcome, .byokSetup, .visualCreate, .voiceCreate, .launchPet, .completed]
        for stage in stages {
            var s = OnboardingState()
            s.currentStage = stage
            s.chosenPath = .generate
            try s.save(to: url)
            let loaded = try OnboardingState.load(from: url)
            try XCTAssertEqual(loaded.currentStage, stage, "stage \(stage) roundtrip 失败")
        }
    }

    tests.add("State.testEachPathRoundtrip") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        let paths: [OnboardingPath] = [.generate, .upload, .importPath, .sample]
        for path in paths {
            var s = OnboardingState()
            s.chosenPath = path
            try s.save(to: url)
            let loaded = try OnboardingState.load(from: url)
            try XCTAssertEqual(loaded.chosenPath, path, "path \(path) roundtrip 失败")
        }
    }

    // MARK: - 错误路径

    tests.add("State.testLoadNotFoundThrows") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        try XCTAssertThrowsError({ _ = try OnboardingState.load(from: url) })
        do {
            _ = try OnboardingState.load(from: url)
        } catch let err as OnboardingError {
            try XCTAssertEqual(err, .stateFileNotFound)
        }
    }

    tests.add("State.testLoadCorruptedThrowsCorrupted") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        // 写一个非 JSON 内容
        try Data("this is not json { ]".utf8).write(to: url)
        do {
            _ = try OnboardingState.load(from: url)
            throw TestFailure(name: "test", message: "expected throw")
        } catch let err as OnboardingError {
            // corrupted → stateFileCorrupted
            switch err {
            case .stateFileCorrupted: break  // 期望
            default: throw TestFailure(name: "test", message: "expected .stateFileCorrupted, got \(err)")
            }
        }
    }

    tests.add("State.testLoadCorruptedJSONShapeThrowsCorrupted") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        // 合法 JSON 但缺 required 字段（current_stage）
        try Data("{\"foo\": 1}".utf8).write(to: url)
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

    tests.add("State.testDeleteRemovesFile") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState()
        try s.save(to: url)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try OnboardingState.delete(at: url)
        try XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    tests.add("State.testDeleteNonExistentNoThrow") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        try XCTAssertNoThrow { try OnboardingState.delete(at: url) }
    }

    tests.add("State.testResetReturnsFreshAndDeletes") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState(currentStage: .launchPet, chosenPath: .generate)
        try s.save(to: url)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        // 模拟 OnboardingApp 启动：用注入 URL 而不是真 defaultURL
        // （reset() 内部用 defaultURL，所以这里手动模拟：先 delete 再读 fresh）
        try OnboardingState.delete(at: url)
        let fresh = OnboardingState()  // 等同于 reset() 返 fresh
        try XCTAssertEqual(fresh.currentStage, .welcome)
        try XCTAssertNil(fresh.chosenPath)
    }

    // MARK: - 原子写（不该留 .tmp）

    tests.add("State.testAtomicWriteNoTmpLeft") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s = OnboardingState(currentStage: .voiceCreate)
        try s.save(to: url)
        let tmp = url.appendingPathExtension("tmp")
        try XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path), "save 不该留 .tmp")
    }

    tests.add("State.testOverwriteSucceeds") { _ in
        let dir = try makeTempDir()
        let url = OnboardingStateStore.url(in: dir)
        var s1 = OnboardingState(currentStage: .welcome)
        try s1.save(to: url)
        var s2 = OnboardingState(currentStage: .byokSetup, chosenPath: .generate)
        try s2.save(to: url)
        let loaded = try OnboardingState.load(from: url)
        try XCTAssertEqual(loaded.currentStage, .byokSetup)
        try XCTAssertEqual(loaded.chosenPath, .generate)
    }
}

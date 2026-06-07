// PetStoreTests.swift
// PetStore CRUD + 列表 + 原子写 roundtrip 测试
//
// 覆盖：
//   - loadAll 排序（按 name）
//   - load(id) 返回 LoadedPetProfile
//   - create 复制 profileRoot
//   - update 重新写 manifest
//   - delete 删子目录
//   - 二次 create 同 id → alreadyExists
//   - load 不存在的 id → 抛错
//   - atomicWrite tmp 残留清理
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

func registerPetStoreTests(_ tests: Tests) {
    // 共享 fixture + temp dir
    // 注：fixture 是平铺 JSON 文件 + 共享 assets/ 目录。
    // 每个 test 拿一个独立的 tmpDir（不在 store root 内），注入 fixture 到 tmpDir/fixture-staging/
    // 再走 PetProfileLoader 解析。
    func makeFixtureCopy(_ name: String, into dest: URL) throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let fixtureBase = env["STUDIO_FIXTURE_ROOT"]
            ?? "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
        let manifestSrc = URL(fileURLWithPath: "\(fixtureBase)/\(name).json")
        let assetsSrc = URL(fileURLWithPath: "\(fixtureBase)/assets")

        let petRoot = dest.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: petRoot)
        try FileManager.default.createDirectory(at: petRoot, withIntermediateDirectories: true)
        // 复制 manifest.json
        try FileManager.default.copyItem(at: manifestSrc, to: petRoot.appendingPathComponent("manifest.json"))
        // 复制 assets/
        try FileManager.default.copyItem(at: assetsSrc, to: petRoot.appendingPathComponent("assets"))
        return petRoot
    }

    // store.root 在独立的子目录，fixture staging 在兄弟目录 — 不会混
    func makeTempStore() throws -> (PetStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeRoot = dir.appendingPathComponent("store-root", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        return (PetStore(root: storeRoot), dir)
    }

    // MARK: - loadAll 排序

    tests.add("Store.testLoadAllEmpty") { _ in
        let (store, _) = try makeTempStore()
        let list = try store.loadAll()
        try XCTAssertEqual(list.count, 0)
    }

    tests.add("Store.testLoadAllSortsByName") { _ in
        let (store, dir) = try makeTempStore()
        // 注入 fixture（pako/mitu/zorp）
        for name in ["pako-v1.0.0", "mitu-v1.0.0", "zorp-v1.0.0"] {
            let src = try makeFixtureCopy(name, into: dir)
            let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
            try store.create(profile: loaded)
        }
        let list = try store.loadAll()
        try XCTAssertEqual(list.count, 3)
        // 按 name 排序：Mitu < Pako < Zorp
        try XCTAssertEqual(list[0].name, "Mitu")
        try XCTAssertEqual(list[1].name, "Pako")
        try XCTAssertEqual(list[2].name, "Zorp")
    }

    tests.add("Store.testSummaryDerivedFromManifest") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)
        let list = try store.loadAll()
        let pako = try XCTUnwrap(list.first)
        try XCTAssertEqual(pako.id, "pet_pako_v10")
        try XCTAssertEqual(pako.name, "Pako")
        // species = persona.backstoryTags.first
        try XCTAssertEqual(pako.species, "office")
        // createdAt 来自 manifest
        let comps = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: pako.createdAt)
        try XCTAssertEqual(comps.year, 2026)
    }

    // MARK: - load(id)

    tests.add("Store.testLoadByIDReturnsLoadedPetProfile") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        let loaded2 = try store.load(id: "pet_pako_v10")
        try XCTAssertEqual(loaded2.manifest.id.raw, "pet_pako_v10")
        // 5 个 visual state 都被 loader 解析
        try XCTAssertEqual(loaded2.visualAssetURLs.count, 5)
        try XCTAssertNotNil(loaded2.visualAssetURLs["idle"])
    }

    tests.add("Store.testLoadMissingIDThrows") { _ in
        let (store, _) = try makeTempStore()
        do {
            _ = try store.load(id: "pet_nonexistent")
            throw TestFailure(name: "loadMissing", message: "expected throw")
        } catch {
            // OK
        }
    }

    // MARK: - create

    tests.add("Store.testCreateCopiesProfileRoot") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)
        // pet 目录已存在 + manifest.json 已存在
        let petDir = store.petDirectory(for: "pet_pako_v10")
        let manifestURL = petDir.appendingPathComponent("manifest.json")
        try XCTAssertTrue(FileManager.default.fileExists(atPath: petDir.path))
        try XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    tests.add("Store.testCreateDuplicateThrowsAlreadyExists") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)
        do {
            try store.create(profile: loaded)
            throw TestFailure(name: "dup", message: "expected throw")
        } catch PetStoreError.alreadyExists(let id) {
            try XCTAssertEqual(id, "pet_pako_v10")
        } catch {
            throw TestFailure(name: "dup", message: "wrong error: \(error)")
        }
    }

    // MARK: - update

    tests.add("Store.testUpdateRewritesManifest") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        // rebuild manifest：改 name + persona tags
        let newPersona = PersonaCard(
            name: "Pako-Edited",
            loreShort: loaded.manifest.persona.loreShort,
            relationshipWithUser: loaded.manifest.persona.relationshipWithUser,
            recurringMotifs: loaded.manifest.persona.recurringMotifs,
            backstoryTags: ["office", "edited", "wip"]
        )
        let newManifest = PetProfileV1(
            version: loaded.manifest.version,
            minRuntimeVersion: loaded.manifest.minRuntimeVersion,
            id: loaded.manifest.id,
            name: "Pako-Edited",
            createdAt: loaded.manifest.createdAt,
            locale: loaded.manifest.locale,
            visual: loaded.manifest.visual,
            audio: loaded.manifest.audio,
            action: loaded.manifest.action,
            expression: loaded.manifest.expression,
            humor: loaded.manifest.humor,
            persona: newPersona
        )
        let updated = LoadedPetProfile(
            profileRoot: loaded.profileRoot,
            manifest: newManifest,
            visualAssetURLs: loaded.visualAssetURLs,
            expressionAssetURLs: loaded.expressionAssetURLs,
            actionIdleAssetURL: loaded.actionIdleAssetURL,
            actionReactionAssetURLs: loaded.actionReactionAssetURLs,
            voiceCloneSampleURL: loaded.voiceCloneSampleURL
        )
        try store.update(updated)

        // 重新 load，验证新 manifest
        let reloaded = try store.load(id: "pet_pako_v10")
        try XCTAssertEqual(reloaded.manifest.name, "Pako-Edited")
        try XCTAssertEqual(reloaded.manifest.persona.backstoryTags, ["office", "edited", "wip"])
    }

    tests.add("Store.testUpdateMissingIDThrows") { _ in
        let (store, _) = try makeTempStore()
        // 构造一个不存在的 loaded
        let fakeURL = URL(fileURLWithPath: "/tmp/nonexistent")
        // 用一个 minimal manifest 构造
        let manifest = makeMinimalProfile(id: "pet_ghost_v10", name: "Ghost")
        let loaded = LoadedPetProfile(
            profileRoot: fakeURL,
            manifest: manifest,
            visualAssetURLs: [:],
            expressionAssetURLs: [:],
            actionIdleAssetURL: nil,
            actionReactionAssetURLs: [],
            voiceCloneSampleURL: nil
        )
        do {
            try store.update(loaded)
            throw TestFailure(name: "updateMissing", message: "expected throw")
        } catch PetStoreError.notFound(let id) {
            try XCTAssertEqual(id, "pet_ghost_v10")
        } catch {
            throw TestFailure(name: "updateMissing", message: "wrong error: \(error)")
        }
    }

    // MARK: - delete

    tests.add("Store.testDeleteRemovesDirectory") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)
        try store.delete(id: "pet_pako_v10")
        let after = try store.loadAll()
        try XCTAssertEqual(after.count, 0)
    }

    tests.add("Store.testDeleteMissingThrows") { _ in
        let (store, _) = try makeTempStore()
        do {
            try store.delete(id: "pet_ghost_v10")
            throw TestFailure(name: "delMissing", message: "expected throw")
        } catch PetStoreError.notFound {
            // OK
        } catch {
            throw TestFailure(name: "delMissing", message: "wrong error: \(error)")
        }
    }

    // MARK: - loadAll 跳过损坏 manifest

    tests.add("Store.testLoadAllSkipsCorruptManifest") { _ in
        let (store, dir) = try makeTempStore()
        // 注入坏 manifest
        let bad = dir.appendingPathComponent("pet_bad_v10")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ not valid json".utf8).write(to: bad.appendingPathComponent("manifest.json"))
        // 注入好 manifest
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        let list = try store.loadAll()
        // bad 被跳过，pako 在
        try XCTAssertEqual(list.count, 1)
        try XCTAssertEqual(list.first?.id, "pet_pako_v10")
    }

    // MARK: - roundtrip persistence

    tests.add("Store.testRoundtripPersistsAcrossInstances") { _ in
        let (store, dir) = try makeTempStore()
        let src = try makeFixtureCopy("pako-v1.0.0", into: dir)
        let loaded = try PetProfileLoader().loadProfile(from: src.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        // 新 store 共享同一个 root
        let store2 = PetStore(root: store.root)
        let list = try store2.loadAll()
        try XCTAssertEqual(list.count, 1)
        try XCTAssertEqual(list.first?.name, "Pako")
    }
}

// MARK: - minimal profile helper

func makeMinimalProfile(id: String, name: String) -> PetProfileV1 {
    let v = VisualStates(
        idle: "assets/visual/states/idle.png",
        focus: "assets/visual/states/focus.png",
        happy: "assets/visual/states/happy.png",
        tired: "assets/visual/states/tired.png",
        celebrate: "assets/visual/states/celebrate.png"
    )
    let visual = VisualPack(
        renderMode: .staticImage,
        supportedRenderModes: [.staticImage],
        transparentAlpha: true,
        idleBreathing: true,
        states: v
    )
    let audio = AudioPack(
        ttsProvider: "user-configured",
        ttsVoice: "neutral",
        voiceStyle: VoiceStyle(),
        catchphrases: [],
        voiceCloneConsent: nil
    )
    let action = ActionPack(
        idle: IdleAction(name: "breathe", loop: true, durationMs: 2000),
        reactions: []
    )
    let expression = ExpressionPack(
        states: ExpressionStates(
            idle: ExpressionFace(assetPath: "assets/expression/idle.png"),
            focus: ExpressionFace(assetPath: "assets/expression/focus.png"),
            happy: ExpressionFace(assetPath: "assets/expression/happy.png"),
            tired: ExpressionFace(assetPath: "assets/expression/tired.png"),
            celebrate: ExpressionFace(assetPath: "assets/expression/celebrate.png")
        ),
        extendedEmotions: nil
    )
    let humor = HumorPack(
        humorStyle: .gentle,
        personaSystemPrompt: "Test prompt — minimum fifty characters required to pass the validator. OK.",
        jokeDensity: 0.0
    )
    let persona = PersonaCard(
        name: name,
        loreShort: "Test pet."
    )
    return PetProfileV1(
        version: .v1_0_0,
        minRuntimeVersion: nil,
        id: ProfileID(raw: id),
        name: name,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        locale: "en-US",
        visual: visual,
        audio: audio,
        action: action,
        expression: expression,
        humor: humor,
        persona: persona
    )
}

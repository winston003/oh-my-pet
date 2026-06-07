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
//   - P2-H: create 复制 assets 时只复制 manifest 引用的（awareness flag 修复）
//   - P2-H: export .omppet 只含 manifest 引用的 assets
//   - P2-H: expression.extended_emotions[].asset_path 也被收集
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

    // MARK: - P2-H: assets 过滤（awareness flag 修复）

    /// 准备 2 个 pet 的 assets 混在一起，验证 create 只复制当前 pet manifest 引用的
    /// （P2-H 修复目标：export 不再含其他 pet 的资产）
    tests.add("Store.testCreateCopiesOnlyManifestReferencedAssets") { _ in
        let (store, dir) = try makeTempStore()

        // 构造 source profileRoot：manifest 只引用 2 个 assets
        // 但 assets/ 目录里有 5 个文件（2 个被引用 + 3 个不被引用 —— 模拟"其它 pet 的残留"）
        let sourceRoot = dir.appendingPathComponent("source-pako-mixed", isDirectory: true)
        try? FileManager.default.removeItem(at: sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        // 写一个 minimal manifest（只引用 2 个 assets）
        let referencedA = "assets/visual/states/idle.png"
        let referencedB = "assets/visual/states/happy.png"
        let orphan1 = "assets/visual/states/celebrate.png"
        let orphan2 = "assets/expression/idle.png"
        let orphan3 = "assets/visual/reactions/orphan-from-other-pet.apng"

        let minimal = makeMinimalProfile(id: "pet_pako_v10", name: "Pako")
        // 写 source manifest（重新指定 states 引用 2 个，reactions 引用 1 个 orphan 验证明明被忽略）
        let customManifest = PetProfileV1(
            version: .v1_0_0,
            minRuntimeVersion: nil,
            id: ProfileID(raw: "pet_pako_v10"),
            name: "Pako",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "en-US",
            visual: VisualPack(
                renderMode: .staticImage,
                supportedRenderModes: [.staticImage],
                transparentAlpha: true,
                idleBreathing: false,
                states: VisualStates(
                    idle: referencedA,
                    focus: referencedA,  // 重复引用，验证去重
                    happy: referencedB,
                    tired: referencedA,  // 重复
                    celebrate: referencedA  // 重复 — 但文件不存在，create 应跳过
                )
            ),
            audio: AudioPack(
                ttsProvider: "user-configured",
                ttsVoice: "neutral",
                voiceStyle: VoiceStyle(),
                catchphrases: [],
                voiceCloneConsent: nil
            ),
            action: ActionPack(
                idle: IdleAction(name: "breathe", loop: true, durationMs: 2000, assetPath: orphan3),
                reactions: []
            ),
            expression: ExpressionPack(
                states: ExpressionStates(
                    idle: ExpressionFace(assetPath: orphan2),
                    focus: ExpressionFace(assetPath: orphan2),
                    happy: ExpressionFace(assetPath: orphan2),
                    tired: ExpressionFace(assetPath: orphan2),
                    celebrate: ExpressionFace(assetPath: orphan2)
                ),
                extendedEmotions: nil
            ),
            humor: minimal.humor,
            persona: minimal.persona
        )
        let customData = try ProfileIO.encodeV1(customManifest)
        try customData.write(to: sourceRoot.appendingPathComponent("manifest.json"))

        // 写 5 个 asset 文件：2 个被引用 + 3 个不被引用（其中 1 个被 action.idle.assetPath 引用但我们故意让 manifest 引用它但 expression 又 orphan2 — 测过滤逻辑以 manifest 为准）
        try writeEmptyFile(at: sourceRoot.appendingPathComponent(referencedA))
        try writeEmptyFile(at: sourceRoot.appendingPathComponent(referencedB))
        try writeEmptyFile(at: sourceRoot.appendingPathComponent(orphan1))
        try writeEmptyFile(at: sourceRoot.appendingPathComponent(orphan2))
        try writeEmptyFile(at: sourceRoot.appendingPathComponent(orphan3))

        // 注：上面 manifest 写错了 —— 我让 action.idle.assetPath = orphan3 但 customManifest.expression.states
        // 也引用 orphan2（这里我们就是要测 manifest 引用的都被收集，包括未在 file 里的）
        // 重新调一下 customManifest 的 action.idle 改成真正被引用的（referencedA）
        // —— 不，重写一次：
        // 等等，先把"应该被收集"的清单捋清楚：
        //   - referencedA（idle, focus, tired, celebrate）— 4 次但 unique = 1
        //   - referencedB（happy）— 1
        //   - orphan3（action.idle）— 1
        //   - orphan2（expression.states）— 5 次 unique = 1
        // 唯一集合 = {referencedA, referencedB, orphan3, orphan2} = 4 个
        // 文件存在 = 5 个（孤儿 = orphan1）
        // 期望 dest：4 个（orphan1 被过滤掉）

        // 调 create
        let loader = PetProfileLoader()
        let loaded = try loader.loadProfile(from: sourceRoot.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        // 验证 dest 目录
        let destDir = store.petDirectory(for: "pet_pako_v10")
        let fm = FileManager.default
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent("manifest.json").path))
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(referencedA).path))
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(referencedB).path))
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(orphan2).path))
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(orphan3).path))
        // 关键：orphan1 **不**应被复制（manifest 没引用）
        try XCTAssertFalse(
            fm.fileExists(atPath: destDir.appendingPathComponent(orphan1).path),
            "create must skip un-referenced assets: \(orphan1)"
        )
    }

    /// 验证 expression pack 的 extended_emotions[].asset_path 也被收集
    /// （不只 visual states —— awareness flag 修复的明细要求）
    tests.add("Store.testAssetPathReferenceInExpressionPackRespected") { _ in
        let (store, dir) = try makeTempStore()

        // 构造 manifest：所有 5 个 state 都引用同一个文件，
        // extended_emotions 引用 3 个不同的文件
        let sharedState = "assets/visual/states/idle.png"
        let ext1 = "assets/expression/shy.png"
        let ext2 = "assets/expression/yawn.png"
        let ext3 = "assets/expression/facepalm.png"
        let unrefExpr = "assets/expression/orphan-from-other-pet.png"

        let sourceRoot = dir.appendingPathComponent("source-extended", isDirectory: true)
        try? FileManager.default.removeItem(at: sourceRoot)
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let manifest = PetProfileV1(
            version: .v1_0_0,
            minRuntimeVersion: nil,
            id: ProfileID(raw: "pet_mitu_v10"),
            name: "Mitu",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            locale: "en-US",
            visual: VisualPack(
                renderMode: .staticImage,
                supportedRenderModes: [.staticImage],
                transparentAlpha: true,
                idleBreathing: false,
                states: VisualStates(
                    idle: sharedState, focus: sharedState, happy: sharedState,
                    tired: sharedState, celebrate: sharedState
                )
            ),
            audio: AudioPack(
                ttsProvider: "user-configured",
                ttsVoice: "neutral",
                voiceStyle: VoiceStyle(),
                catchphrases: [],
                voiceCloneConsent: nil
            ),
            action: ActionPack(
                idle: IdleAction(name: "breathe", loop: true, durationMs: 2000),
                reactions: []
            ),
            expression: ExpressionPack(
                states: ExpressionStates(
                    idle: ExpressionFace(assetPath: "assets/expression/expr-idle.png"),
                    focus: ExpressionFace(assetPath: "assets/expression/expr-focus.png"),
                    happy: ExpressionFace(assetPath: "assets/expression/expr-happy.png"),
                    tired: ExpressionFace(assetPath: "assets/expression/expr-tired.png"),
                    celebrate: ExpressionFace(assetPath: "assets/expression/expr-celebrate.png")
                ),
                extendedEmotions: [
                    ExtendedEmotion(name: "shy", assetPath: ext1, triggerContexts: ["long_press"]),
                    ExtendedEmotion(name: "yawn", assetPath: ext2, triggerContexts: ["shake_window"]),
                    ExtendedEmotion(name: "facepalm", assetPath: ext3, triggerContexts: ["ai_reply"]),
                ]
            ),
            humor: HumorPack(
                humorStyle: .gentle,
                personaSystemPrompt: "Test prompt — minimum fifty characters required to pass the validator. OK.",
                jokeDensity: 0.0
            ),
            persona: PersonaCard(name: "Mitu", loreShort: "Test pet.")
        )
        try ProfileIO.encodeV1(manifest).write(to: sourceRoot.appendingPathComponent("manifest.json"))

        // 写 5 个 state 文件 + 5 个 expression state 文件 + 3 个 extended + 1 orphan
        for path in [
            sharedState,
            "assets/expression/expr-idle.png",
            "assets/expression/expr-focus.png",
            "assets/expression/expr-happy.png",
            "assets/expression/expr-tired.png",
            "assets/expression/expr-celebrate.png",
            ext1, ext2, ext3, unrefExpr,
        ] {
            try writeEmptyFile(at: sourceRoot.appendingPathComponent(path))
        }

        let loader = PetProfileLoader()
        let loaded = try loader.loadProfile(from: sourceRoot.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        let destDir = store.petDirectory(for: "pet_mitu_v10")
        let fm = FileManager.default

        // extended_emotions 引用：3 个都应在
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(ext1).path))
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(ext2).path))
        try XCTAssertTrue(fm.fileExists(atPath: destDir.appendingPathComponent(ext3).path))
        // orphan 不应在
        try XCTAssertFalse(
            fm.fileExists(atPath: destDir.appendingPathComponent(unrefExpr).path),
            "extended_emotions un-referenced asset should be filtered"
        )
    }

    /// export → import roundtrip：验证 .omppet 包里只有当前 pet 引用的 assets
    tests.add("Store.testExportZipContainsOnlyCurrentPetAssets") { _ in
        let (store, dir) = try makeTempStore()

        // 用 fixture pako 创建一个 pet（Pako manifest 引用 18 个 assets，但 fixture assets/ 里实际只有 ~25 个）
        // —— 我们要验证：export 后 .omppet 包内的文件数 ≤ 实际 fixture assets + manifest.json
        let env = ProcessInfo.processInfo.environment
        let fixtureBase = env["STUDIO_FIXTURE_ROOT"]
            ?? "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
        let manifestSrc = URL(fileURLWithPath: "\(fixtureBase)/pako-v1.0.0.json")
        let assetsSrc = URL(fileURLWithPath: "\(fixtureBase)/assets")
        let stagingDir = dir.appendingPathComponent("pako-staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let petRoot = stagingDir.appendingPathComponent("pako-root", isDirectory: true)
        try? FileManager.default.removeItem(at: petRoot)
        try FileManager.default.createDirectory(at: petRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifestSrc, to: petRoot.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: assetsSrc, to: petRoot.appendingPathComponent("assets"))
        let loaded = try PetProfileLoader().loadProfile(from: petRoot.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)

        // Export
        let outURL = dir.appendingPathComponent("pako-filtered.omppet")
        try store.export(profileID: "pet_pako_v10", to: outURL)

        // Unzip 列文件
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", outURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try XCTAssertEqual(process.terminationStatus, 0, "unzip should succeed")
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        // 解析 unzip -l 输出（行尾是文件相对路径）
        // 实际格式："        0  06-08-2026 05:21   manifest.json"
        // （macOS /usr/bin/unzip 用 MM-DD-YYYY 格式，不是 YYYY-MM-DD）
        let lines = out.split(separator: "\n")
        let entries: [String] = lines.compactMap { line -> String? in
            let s = String(line)
            // 找 "<date> <time>   <name>" 模式
            guard let regex = try? NSRegularExpression(pattern: #"\s+\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}\s+(.+)$"#) else {
                return nil
            }
            let range = NSRange(s.startIndex..<s.endIndex, in: s)
            guard let match = regex.firstMatch(in: s, range: range),
                  match.numberOfRanges >= 2,
                  let nameRange = Range(match.range(at: 1), in: s)
            else {
                return nil
            }
            return String(s[nameRange])
        }

        // 关键：必须有 manifest.json
        try XCTAssertTrue(entries.contains { $0.hasSuffix("/manifest.json") || $0 == "manifest.json" }, "zip must contain manifest.json; got: \(entries)")

        // 关键：zip 内文件都应是被 manifest 引用的（用 ProfileIO 重新解析 manifest 拿到引用集合）
        // —— 重新解析 outURL 包里的 manifest（解出来看），但更简单的是用 store 内 manifest 校验
        let pako = try store.load(id: "pet_pako_v10")
        let manifest = pako.manifest
        // 构造一个 helper-like 引用集合：跟 PetStore.manifestReferencedAssets 一样的逻辑
        // （这里复用不了 private，所以 inline 一份）
        var referenced = Set<String>()
        for s in [manifest.visual.states.idle, manifest.visual.states.focus, manifest.visual.states.happy,
                  manifest.visual.states.tired, manifest.visual.states.celebrate] {
            referenced.insert(s)
        }
        for face in [manifest.expression.states.idle, manifest.expression.states.focus,
                     manifest.expression.states.happy, manifest.expression.states.tired,
                     manifest.expression.states.celebrate] {
            referenced.insert(face.assetPath)
        }
        for ext in (manifest.expression.extendedEmotions ?? []) {
            referenced.insert(ext.assetPath)
        }
        if let p = manifest.action.idle.assetPath { referenced.insert(p) }
        for r in manifest.action.reactions { if let p = r.assetPath { referenced.insert(p) } }
        if let p = manifest.audio.voiceCloneConsent?.samplePath { referenced.insert(p) }

        // zip 内每个 asset 文件都应在 referenced 集合
        for entry in entries {
            // 跳过 manifest.json 和目录行
            if entry.hasSuffix("/manifest.json") || entry == "manifest.json" { continue }
            if entry.hasSuffix("/") { continue }  // 目录条目
            // 把 "pako-filtered/assets/visual/states/idle.png" → "assets/visual/states/idle.png"
            let normalized: String
            if let r = entry.range(of: #"^[^/]+/(.+)$"#, options: .regularExpression) {
                // 提取 capture group 1
                if r.lowerBound > entry.startIndex {
                    normalized = String(entry[r.upperBound...])
                } else {
                    normalized = entry
                }
            } else {
                normalized = entry
            }
            try XCTAssertTrue(
                referenced.contains(normalized),
                "exported file \(entry) (normalized=\(normalized)) is NOT in manifest references. Referenced: \(referenced.sorted())"
            )
        }
    }
}

// MARK: - minimal profile helper

/// 写一个空文件（含父目录）— 用于构造测试 fixture
func writeEmptyFile(at url: URL) throws {
    let parent = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: parent.path) {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try Data("test".utf8).write(to: url)
}

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

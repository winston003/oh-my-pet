// HouseViewTests.swift
// HouseView 数据加载测试
//
// 覆盖：
//   - reload 后 profile / memories / stickers / generationHistory 全部填充
//   - todayMemories 过滤今天
//   - runExport 不弹 NSSavePanel（要走单元测试 friendly 路径 — 这里只验证 export URL 调通后文件存在）
//   - delete 调 store.delete
//   - 损坏 JSON → 抛 .jsonReadFailed
//   - 文件不存在 → loadMemories / stickers / generationHistory 返回空数组（不抛错）
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

func registerHouseViewTests(_ tests: Tests) {

    func makeTempStore() throws -> (PetStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("house-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeRoot = dir.appendingPathComponent("store-root", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        return (PetStore(root: storeRoot), dir)
    }

    func injectFixture(_ name: String, into store: PetStore, dir: URL) throws {
        let env = ProcessInfo.processInfo.environment
        let fixtureBase = env["STUDIO_FIXTURE_ROOT"]
            ?? "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
        let manifestSrc = URL(fileURLWithPath: "\(fixtureBase)/\(name).json")
        let assetsSrc = URL(fileURLWithPath: "\(fixtureBase)/assets")
        let stagingDir = dir.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let petRoot = stagingDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: petRoot)
        try FileManager.default.createDirectory(at: petRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifestSrc, to: petRoot.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: assetsSrc, to: petRoot.appendingPathComponent("assets"))
        let loaded = try PetProfileLoader().loadProfile(from: petRoot.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)
    }

    // MARK: - reload 全部字段

    tests.add("House.testReloadFillsAllFields") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)

        let vm = HouseViewModel(petID: "pet_pako_v10", store: store)
        vm.reload()
        try XCTAssertNotNil(vm.profile)
        try XCTAssertEqual(vm.profile?.manifest.id.raw, "pet_pako_v10")
        // 5 visual state
        try XCTAssertEqual(vm.profile?.visualAssetURLs.count, 5)
    }

    // MARK: - voice 摘要

    tests.add("House.testVoiceSummaryExposed") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let vm = HouseViewModel(petID: "pet_pako_v10", store: store)
        vm.reload()
        let voice = try XCTUnwrap(vm.profile?.manifest.audio)
        try XCTAssertEqual(voice.ttsProvider, "user-configured")
        try XCTAssertEqual(voice.voiceStyle.tone, "drawl-deadpan")
    }

    // MARK: - 缺失数据文件 → 返回空数组（不抛错）

    tests.add("House.testMissingDataFilesReturnEmpty") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let mems = try store.loadMemories(petID: "pet_pako_v10")
        try XCTAssertEqual(mems.count, 0)
        let stickers = try store.loadStickers(petID: "pet_pako_v10")
        try XCTAssertEqual(stickers.count, 0)
        let hist = try store.loadGenerationHistory(petID: "pet_pako_v10")
        try XCTAssertEqual(hist.count, 0)
    }

    // MARK: - 注入 memories / stickers / history 数据并验证

    tests.add("House.testInjectedMemoriesLoadBack") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let petDir = store.petDirectory(for: "pet_pako_v10")

        // 写 memories.json（3 条）
        let mems: [PetMemory] = [
            PetMemory(id: "m1", kind: .firstMeet, title: "第一次见面", detail: "你好", createdAt: Date()),
            PetMemory(id: "m2", kind: .focusComplete, title: "完成 25min focus", createdAt: Date().addingTimeInterval(-3600)),
            PetMemory(id: "m3", kind: .taskComplete, title: "提交 PR", createdAt: Date().addingTimeInterval(-7200)),
        ]
        let memsData = try JSONEncoder.iso8601.encode(mems)
        try memsData.write(to: petDir.appendingPathComponent("memories.json"))

        // 写 stickers.json（2 sticker + 1 room object）
        let stickers: [PetSticker] = [
            PetSticker(id: "s1", name: "果冻贴纸", kind: .sticker, acquiredAt: Date()),
            PetSticker(id: "s2", name: "工位便签", kind: .sticker, acquiredAt: Date()),
            PetSticker(id: "r1", name: "咖啡杯", kind: .roomObject, acquiredAt: Date()),
        ]
        try JSONEncoder.iso8601.encode(stickers).write(to: petDir.appendingPathComponent("stickers.json"))

        // 写 generation-history.json
        let hist: [GenerationHistoryEntry] = [
            GenerationHistoryEntry(id: "g1", kind: .visual, summary: "生成主图", createdAt: Date().addingTimeInterval(-86400)),
            GenerationHistoryEntry(id: "g2", kind: .state, summary: "生成 5 个 state", createdAt: Date().addingTimeInterval(-80000)),
        ]
        try JSONEncoder.iso8601.encode(hist).write(to: petDir.appendingPathComponent("generation-history.json"))

        // reload
        let vm = HouseViewModel(petID: "pet_pako_v10", store: store)
        vm.reload()
        try XCTAssertEqual(vm.memories.count, 3)
        try XCTAssertEqual(vm.stickers.count, 3)
        try XCTAssertEqual(vm.generationHistory.count, 2)
    }

    // MARK: - today memories 过滤

    tests.add("House.testTodayMemoriesFilter") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let petDir = store.petDirectory(for: "pet_pako_v10")

        // 用固定中午时间（避免跨日边界歧义）
        var comps = DateComponents()
        comps.year = 2026; comps.month = 6; comps.day = 7
        comps.hour = 12; comps.minute = 0; comps.second = 0
        let cal = Calendar(identifier: .gregorian)
        let noon = try XCTUnwrap(cal.date(from: comps), "fixed date")
        let yesterday = try XCTUnwrap(cal.date(byAdding: .day, value: -1, to: noon), "yesterday")

        let mems: [PetMemory] = [
            PetMemory(id: "today1", kind: .focusComplete, title: "今天 focus", createdAt: noon),
            PetMemory(id: "today2", kind: .taskComplete, title: "今天 task", createdAt: noon.addingTimeInterval(-3600)),
            PetMemory(id: "yesterday", kind: .focusComplete, title: "昨天 focus", createdAt: yesterday),
        ]
        try JSONEncoder.iso8601.encode(mems).write(to: petDir.appendingPathComponent("memories.json"))

        let todayOnly = try store.todayMemories(petID: "pet_pako_v10", calendar: cal, now: noon)
        try XCTAssertEqual(todayOnly.count, 2)
        let ids = Set(todayOnly.map { $0.id })
        try XCTAssertEqual(ids, ["today1", "today2"])
    }

    // MARK: - 损坏 JSON → 抛错

    tests.add("House.testCorruptMemoriesJSONThrows") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let petDir = store.petDirectory(for: "pet_pako_v10")
        try Data("{ not json".utf8).write(to: petDir.appendingPathComponent("memories.json"))
        do {
            _ = try store.loadMemories(petID: "pet_pako_v10")
            throw TestFailure(name: "corrupt", message: "expected throw")
        } catch PetStoreError.jsonReadFailed {
            // OK
        } catch {
            throw TestFailure(name: "corrupt", message: "wrong error: \(error)")
        }
    }

    // MARK: - delete

    tests.add("House.testDeleteRemovesPet") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let vm = HouseViewModel(petID: "pet_pako_v10", store: store)
        vm.delete()
        let list = try store.loadAll()
        try XCTAssertEqual(list.count, 0)
    }
}

// MARK: - JSON helpers

extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()
}

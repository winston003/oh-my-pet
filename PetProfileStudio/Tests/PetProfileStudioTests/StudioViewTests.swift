// StudioViewTests.swift
// StudioView 状态机 + SamplePet 路径解析测试
//
// 覆盖：
//   - StudioViewModel.reload 后 summaries 填充
//   - beginCreate 切到 .create editor mode
//   - beginEdit 切到 .edit(originalID:) editor mode
//   - commitEditor 在 .create 路径下：拷贝 sample + 应用 draft
//   - commitEditor 在 .edit 路径下：重写 manifest
//   - cancelEditor 回到 .none
//   - delete 调 store.delete
//   - SamplePet.builtInSamples 3 只，id 各异
//   - 排序走 loadAll（已测过；这里只 smoke test VM 走通）
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

func registerStudioViewTests(_ tests: Tests) {

    func makeTempStore() throws -> (PetStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("studio-vm-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
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

    // MARK: - SamplePet

    tests.add("StudioView.testBuiltInSamples") { _ in
        let samples = SamplePet.builtInSamples
        try XCTAssertEqual(samples.count, 3)
        let ids = Set(samples.map { $0.id })
        try XCTAssertEqual(ids, ["pako", "mitu", "zorp"])
    }

    // MARK: - ViewModel: reload

    tests.add("StudioView.testReloadFillsSummaries") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        try injectFixture("mitu-v1.0.0", into: store, dir: dir)

        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.reload()
        try XCTAssertEqual(vm.summaries.count, 2)
        try XCTAssertEqual(vm.summaries[0].name, "Mitu")
        try XCTAssertEqual(vm.summaries[1].name, "Pako")
    }

    // MARK: - ViewModel: editor mode transitions

    tests.add("StudioView.testBeginCreate") { _ in
        let (store, _) = try makeTempStore()
        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.beginCreate()
        try XCTAssertEqual(vm.editorMode, .create)
    }

    tests.add("StudioView.testBeginEdit") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.reload()
        let pako = try XCTUnwrap(vm.summaries.first { $0.id == "pet_pako_v10" })
        vm.beginEdit(pako)
        try XCTAssertEqual(vm.editorMode, .edit(originalID: "pet_pako_v10"))
        try XCTAssertEqual(vm.draft.name, "Pako")
    }

    tests.add("StudioView.testCancelEditor") { _ in
        let (store, _) = try makeTempStore()
        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.beginCreate()
        try XCTAssertEqual(vm.editorMode, .create)
        vm.cancelEditor()
        try XCTAssertEqual(vm.editorMode, .none)
    }

    // MARK: - ViewModel: commitEditor in .create

    tests.add("StudioView.testCommitCreateFromSample") { _ in
        let (store, _) = try makeTempStore()
        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.beginCreate()
        vm.draft.name = "MyPako"
        vm.draft.sampleID = "pako"
        vm.draft.personalityTags = ["office", "wip"]
        vm.draft.voiceTone = "drawl-deadpan"
        vm.commitEditor()

        if let err = vm.error {
            throw TestFailure(name: "create", message: "vm.error: \(err)")
        }
        try XCTAssertEqual(vm.editorMode, .none)
        // pet 已落盘
        let list = try store.loadAll()
        try XCTAssertEqual(list.count, 1)
        let created = try XCTUnwrap(list.first)
        try XCTAssertEqual(created.name, "MyPako")
        try XCTAssertEqual(created.id, "pet_pako_v10")  // sample id 保持
    }

    // MARK: - ViewModel: commitEditor in .edit

    tests.add("StudioView.testCommitEdit") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.reload()
        let pako = try XCTUnwrap(vm.summaries.first { $0.id == "pet_pako_v10" })
        vm.beginEdit(pako)
        vm.draft.name = "Pako-Renamed"
        vm.commitEditor()

        let list = try store.loadAll()
        let updated = try XCTUnwrap(list.first)
        try XCTAssertEqual(updated.name, "Pako-Renamed")
    }

    // MARK: - ViewModel: delete

    tests.add("StudioView.testDeletePet") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let vm = StudioViewModel(store: store, availableSamples: SamplePet.builtInSamples)
        vm.reload()
        let pako = try XCTUnwrap(vm.summaries.first { $0.id == "pet_pako_v10" })
        vm.delete(pako)
        let list = try store.loadAll()
        try XCTAssertEqual(list.count, 0)
    }

    // MARK: - PetDraft.apply

    tests.add("StudioView.testPetDraftApply") { _ in
        let base = makeMinimalProfile(id: "pet_drafttest_v10", name: "Original")
        let draft = PetDraft(
            name: "NewName",
            sampleID: "pako",
            personalityTags: ["warm", "gentle"],
            voiceTone: "warm-gentle"
        )
        let updated = draft.apply(to: base)
        try XCTAssertEqual(updated.name, "NewName")
        try XCTAssertEqual(updated.persona.backstoryTags, ["warm", "gentle"])
        try XCTAssertEqual(updated.audio.voiceStyle.tone, "warm-gentle")
        try XCTAssertEqual(updated.id.raw, "pet_drafttest_v10")  // id 保持
    }
}

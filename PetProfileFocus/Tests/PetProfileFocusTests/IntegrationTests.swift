// IntegrationTests.swift
// 端到端集成测试 — 跟 5 个上游 Package 的集成 + main 流程的镜像
//
// 覆盖：
//   - 跟 PetProfileRuntime.PetActionRouter 集成（focus_start 触发 focus 状态）
//   - 跟 PetProfileStudio.PetStore 集成（memory 可读）
//   - 跟 PetProfileStudio.PetHouseMemoryBridge（SharedMemory → PetMemory）
//   - 跟 PetProfileKit.PetProfileV1（petID 来自 manifest.id.raw）
//   - 跟 PetProfileBrain（不直接依赖，但保证 build 通过）
//   - 跟 PetProfileOnboarding（不直接依赖，但保证 build 通过）
//   - 端到端：start focus → 走完 25 min → complete → 写 memory → PetStore 加载验证
//   - 端到端：add 3 task → complete 2 → abandon 1 → memory + task state
//
import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain
import PetProfileOnboarding
import PetProfileStudio
@testable import PetProfileFocus

func registerIntegrationTests(_ tests: Tests) {

    // 辅助：加载 Pako fixture 到 tmp + 构造 router
    func makePakoProfile() throws -> LoadedPetProfile {
        let original = try XCTUnwrap(
            Bundle.module.url(forResource: "pako-v1.0.0", withExtension: "json", subdirectory: "Fixtures"),
            "missing pako fixture"
        )
        let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("integration-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
        let dest = tmpRoot.appendingPathComponent("pako-v1.0.0.json")
        try FileManager.default.copyItem(at: original, to: dest)
        return try PetProfileLoader().loadProfile(from: dest)
    }

    func makeTmpDir(_ suffix: String) -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("integ-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - PetActionRouter 集成（focus_start → focus 状态）

    tests.add("Integration.testFocusStartTriggersRouterFocusState") { _ in
        let profile = try makePakoProfile()
        let panel = PetPanel(profile: profile)
        let router = PetActionRouter(profile: profile, panel: panel)

        let memStore = MemoryStore(root: makeTmpDir("mem"))
        let session = FocusSession(memoryStore: memStore)
        session.router = router
        session.petID = profile.manifest.id.raw
        session.petName = profile.manifest.name

        try XCTAssertEqual(router.currentState, .idle, "initial state must be .idle")
        try session.start()
        try XCTAssertEqual(router.currentState, .focus, "router must react to .focusStart via FocusSession.start()")
    }

    tests.add("Integration.testCompleteTriggersRouterCelebrate") { _ in
        let profile = try makePakoProfile()
        let panel = PetPanel(profile: profile)
        let router = PetActionRouter(profile: profile, panel: panel)

        let memStore = MemoryStore(root: makeTmpDir("mem"))
        let clock = MockClock()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: memStore)
        session.router = router
        session.petID = profile.manifest.id.raw
        session.petName = profile.manifest.name

        try session.start()
        clock.advance(1500)
        _ = try session.complete()
        try XCTAssertEqual(router.currentState, .celebrate, "complete must trigger .taskDone → celebrate")
    }

    tests.add("Integration.testAbandonTriggersRouterIdle") { _ in
        let profile = try makePakoProfile()
        let panel = PetPanel(profile: profile)
        let router = PetActionRouter(profile: profile, panel: panel)

        let memStore = MemoryStore(root: makeTmpDir("mem"))
        let clock = MockClock()
        let session = FocusSession(clock: clock.nowProvider, memoryStore: memStore)
        session.router = router
        session.petID = profile.manifest.id.raw
        session.petName = profile.manifest.name

        try session.start()
        clock.advance(300)
        try session.abandon()
        try XCTAssertEqual(router.currentState, .idle, "abandon must trigger .focusEnd → idle")
    }

    // MARK: - PetStore 集成（Pet House Tab 记忆可读）

    tests.add("Integration.testMemoryStoreIsReadableLikePetHouseTab") { _ in
        // 模拟 "Pet House Tab 读 memory"：直接调 MemoryStore.load(forPetID:)，
        // 跟 PetStore.loadMemories(petID:) 的 API 形状对齐（都是 petID → [memory]）。
        // 因为 PetStore 是 frozen，本集成通过 MemoryStore 走；PetStore 本身不受影响。
        let memStore = MemoryStore(root: makeTmpDir("mem-house"))
        let mem = SharedMemory(
            petID: "pet_pako_v10",
            type: .focus,
            title: "Pako 陪你专注了 25 分钟",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1500
        )
        try memStore.append(mem)

        // "Pet House Tab" 读
        let memoriesForHouse = try memStore.load(forPetID: "pet_pako_v10")
        try XCTAssertEqual(memoriesForHouse.count, 1)
        try XCTAssertEqual(memoriesForHouse.first?.title, "Pako 陪你专注了 25 分钟")
    }

    tests.add("Integration.testPetStoreLoadAllNotImpactedByMemoryStore") { _ in
        // PetStore 跑自己的 loadAll（空 tmp root）→ 0 pets；MemoryStore 写自己
        // 的 memories，互不干扰。
        let petStore = PetStore(root: makeTmpDir("pet"))
        let memStore = MemoryStore(root: makeTmpDir("mem"))

        try memStore.append(SharedMemory(petID: "pet_x", type: .focus, title: "x"))

        let pets = try petStore.loadAll()
        try XCTAssertEqual(pets.count, 0, "PetStore must not see MemoryStore's data")

        // 反向：MemoryStore 不受 PetStore 影响
        let memories = try memStore.loadAll()
        try XCTAssertEqual(memories.count, 1)
    }

    tests.add("Integration.testPetStoreCoexistsWithMemoryStore") { _ in
        // 同一进程内同时跑 PetStore CRUD + MemoryStore CRUD → 互不干扰
        let petStore = PetStore(root: makeTmpDir("pet-co"))
        let memStore = MemoryStore(root: makeTmpDir("mem-co"))
        // PetStore: create Pako from fixture
        let profile = try makePakoProfile()
        try petStore.create(profile: profile)
        let pets = try petStore.loadAll()
        try XCTAssertEqual(pets.count, 1)
        // MemoryStore: write memory for same pet
        try memStore.append(SharedMemory(
            petID: profile.manifest.id.raw,
            type: .focus,
            title: "Pako 陪你",
            durationSeconds: 600
        ))
        let mems = try memStore.loadAll()
        try XCTAssertEqual(mems.count, 1)
        // PetStore 不受 memory store 影响
        let petsAfter = try petStore.loadAll()
        try XCTAssertEqual(petsAfter.count, 1, "PetStore count unchanged")
    }

    // MARK: - PetHouseMemoryBridge（SharedMemory → PetMemory）

    tests.add("Integration.testBridgeConvertsFocusMemoryToPetMemory") { _ in
        let mem = SharedMemory(
            petID: "pet_x",
            type: .focus,
            title: "Pako 陪你专注了 25 分钟",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1500,
            metadata: ["task_name": "写设计稿"]
        )
        let petMem = PetHouseMemoryBridge.toPetMemory(mem)
        try XCTAssertEqual(petMem.kind, .focusComplete, ".focus → .focusComplete")
        try XCTAssertEqual(petMem.title, "Pako 陪你专注了 25 分钟")
        try XCTAssertEqual(petMem.id, mem.id.uuidString)
        try XCTAssertNotNil(petMem.detail)
    }

    tests.add("Integration.testBridgeConvertsTaskMemoryToPetMemory") { _ in
        let taskID = UUID()
        let mem = SharedMemory(
            petID: "pet_x",
            type: .task,
            title: "Pako 看你完成了「写代码」",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: ["task_id": taskID.uuidString, "task_name": "写代码"]
        )
        let petMem = PetHouseMemoryBridge.toPetMemory(mem)
        try XCTAssertEqual(petMem.kind, .taskComplete, ".task → .taskComplete")
        try XCTAssertEqual(petMem.id, mem.id.uuidString)
    }

    tests.add("Integration.testBridgePetMemoriesReturnsArray") { _ in
        let memStore = MemoryStore(root: makeTmpDir("mem-bridge"))
        let now = Date()
        try memStore.append(SharedMemory(
            petID: "pet_pako", type: .focus, title: "f",
            createdAt: now.addingTimeInterval(0), durationSeconds: 1500
        ))
        try memStore.append(SharedMemory(
            petID: "pet_pako", type: .task, title: "t1",
            createdAt: now.addingTimeInterval(10),
            metadata: ["task_id": UUID().uuidString, "task_name": "task1"]
        ))
        let petMems = try PetHouseMemoryBridge.petMemories(petID: "pet_pako", store: memStore)
        try XCTAssertEqual(petMems.count, 2)
        let kinds = Set(petMems.map { $0.kind })
        try XCTAssertTrue(kinds.contains(.focusComplete))
        try XCTAssertTrue(kinds.contains(.taskComplete))
    }

    // MARK: - 端到端：focus 流程

    tests.add("Integration.testEndToEndFocusFlow") { _ in
        let profile = try makePakoProfile()
        let petID = profile.manifest.id.raw
        let petName = profile.manifest.name

        let memStore = MemoryStore(root: makeTmpDir("e2e-mem"))
        let taskRoot = makeTmpDir("e2e-task")
        let panel = PetPanel(profile: profile)
        let router = PetActionRouter(profile: profile, panel: panel)
        let clock = MockClock()

        let session = FocusSession(clock: clock.nowProvider, memoryStore: memStore)
        session.router = router
        session.petID = petID
        session.petName = petName
        let tracker = TaskTracker(root: taskRoot, memoryStore: memStore)
        tracker.router = router
        tracker.petID = petID
        tracker.petName = petName

        // 走完 focus 流程
        try session.start()
        try XCTAssertEqual(router.currentState, .focus)
        clock.advance(1500)  // 25 min
        let memory = try session.complete()
        try XCTAssertEqual(memory.type, .focus)
        try XCTAssertEqual(router.currentState, .celebrate)

        // 验 memory 写到 disk
        let allMem = try memStore.load(forPetID: petID)
        try XCTAssertEqual(allMem.count, 1)
        try XCTAssertEqual(allMem.first?.type, .focus)

        // 验 PetStore 不受影响（fresh root）
        let petStore = PetStore(root: makeTmpDir("e2e-pet"))
        let pets = try petStore.loadAll()
        try XCTAssertEqual(pets.count, 0)

        _ = tracker  // silence unused warning; tracker wired for completeness
    }

    // MARK: - 端到端：task 流程

    tests.add("Integration.testEndToEndTaskFlow") { _ in
        let profile = try makePakoProfile()
        let petID = profile.manifest.id.raw
        let petName = profile.manifest.name

        let memStore = MemoryStore(root: makeTmpDir("e2e-task-mem"))
        let taskRoot = makeTmpDir("e2e-task-task")
        let panel = PetPanel(profile: profile)
        let router = PetActionRouter(profile: profile, panel: panel)

        let tracker = TaskTracker(root: taskRoot, memoryStore: memStore)
        tracker.router = router
        tracker.petID = petID
        tracker.petName = petName

        // add 3 tasks
        let t1 = Task(name: "task1")
        let t2 = Task(name: "task2")
        let t3 = Task(name: "task3")
        for t in [t1, t2, t3] {
            try tracker.add(t)
        }
        // complete 2
        _ = try tracker.complete(id: t1.id)
        _ = try tracker.complete(id: t2.id)
        // abandon 1
        try tracker.abandon(id: t3.id)

        // 验 task state
        let open = try tracker.list(filter: .open)
        let completed = try tracker.list(filter: .completed)
        let abandoned = try tracker.list(filter: .abandoned)
        try XCTAssertEqual(open.count, 0)
        try XCTAssertEqual(completed.count, 2)
        try XCTAssertEqual(abandoned.count, 1)

        // 验 memory: 2 task 完成 → 2 memory
        let mems = try memStore.load(forPetID: petID)
        try XCTAssertEqual(mems.count, 2)
        try XCTAssertTrue(mems.allSatisfy { $0.type == .task })

        // 验 router 收 taskDone（最后一次 complete 后 state = celebrate）
        try XCTAssertEqual(router.currentState, .celebrate)
    }

    // MARK: - PetProfileKit petID 来源

    tests.add("Integration.testPetIDFromManifest") { _ in
        let profile = try makePakoProfile()
        // petID 来自 manifest.id.raw（PetProfileV1 标准字段）
        try XCTAssertEqual(profile.manifest.id.raw, "pet_pako_v10")
        // 让 SharedMemory 用这个 id
        let mem = SharedMemory(
            petID: profile.manifest.id.raw,
            type: .focus,
            title: "x"
        )
        try XCTAssertEqual(mem.petID, "pet_pako_v10")
    }

    // MARK: - 跨上游 Package 的 build 验证

    tests.add("Integration.testAllFiveUpstreamPackagesAreImported") { _ in
        // 此测试单纯验证 import 5 个上游 Package + 本包 build 通过；
        // 实际 type-check 在 swift build 时已经做了，这里只是显式声明。
        // 通过引用各 Package 的公共类型来强制 build-time 链接。
        let _: PetProfileV1.Type = PetProfileV1.self
        let _: PetActionRouter.Type = PetActionRouter.self
        let _: Brain.Type = Brain.self
        let _: OnboardingState.Type = OnboardingState.self
        let _: PetStore.Type = PetStore.self
        let _: SharedMemory.Type = SharedMemory.self
        let _: TaskTracker.Type = TaskTracker.self
        let _: FocusSession.Type = FocusSession.self
        // 都通过编译 → 上游 5 + 本包 3 公共类型都可访问
        try XCTAssertTrue(true)
    }
}
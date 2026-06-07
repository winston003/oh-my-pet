// TaskTrackerTests.swift
// TaskTracker 单元测试 — CRUD + 持久化 + 跟 PetActionRouter 集成
//
// 覆盖：
//   - add → 写到 per-task 文件 + index
//   - complete → 写 task memory + router.handle(.taskDone) + 更新 task 文件 + index
//   - abandon → 不写 memory，不触发 router + 更新 task
//   - list(open / completed / abandoned / all)
//   - 持久化跨实例：关掉 tracker 重开，list 还能读到
//   - 重复 complete / abandon → throw
//   - 不存在的 id → throw
//   - TaskTracker 跟 FocusSession 不耦合（独立使用 OK）
//
import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
@testable import PetProfileFocus

func registerTaskTrackerTests(_ tests: Tests) {

    // 辅助：构造 tmp root
    func makeTmpRoot(_ suffix: String) -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("task-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    func makeTracker(memRoot: URL? = nil, petRoot: URL? = nil) -> (TaskTracker, MemoryStore, PetActionRouter?) {
        let taskRoot = makeTmpRoot("task")
        let actualMemRoot = memRoot ?? makeTmpRoot("mem")
        let memStore = MemoryStore(root: actualMemRoot)
        let tracker = TaskTracker(root: taskRoot, memoryStore: memStore)
        tracker.petID = "pet_test"
        tracker.petName = "TestPet"

        // 可选 router
        var router: PetActionRouter? = nil
        if petRoot != nil {
            // 加载 Pako fixture
            let original = try? XCTUnwrap(
                Bundle.module.url(forResource: "pako-v1.0.0", withExtension: "json", subdirectory: "Fixtures")
            )
            if let original = original {
                let tmpProfileRoot = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("task-fixture-\(UUID().uuidString)", isDirectory: true)
                try? FileManager.default.createDirectory(at: tmpProfileRoot, withIntermediateDirectories: true)
                let dest = tmpProfileRoot.appendingPathComponent("pako-v1.0.0.json")
                try? FileManager.default.copyItem(at: original, to: dest)
                if let profile = try? PetProfileLoader().loadProfile(from: dest) {
                    let panel = PetPanel(profile: profile)
                    router = PetActionRouter(profile: profile, panel: panel)
                }
            }
        }
        if let r = router {
            tracker.router = r
        }
        return (tracker, memStore, router)
    }

    // MARK: - add

    tests.add("TaskTracker.testAddWritesTaskFileAndIndex") { _ in
        let (tracker, _, _) = makeTracker()
        let task = Task(name: "写设计稿")
        try tracker.add(task)

        // 验证文件存在
        let fileURL = tracker.taskFile(for: task.id)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // 验证 index.json 存在
        try XCTAssertTrue(FileManager.default.fileExists(atPath: tracker.indexURL.path))

        // list
        let listed = try tracker.list(filter: .all)
        try XCTAssertEqual(listed.count, 1)
        try XCTAssertEqual(listed.first?.name, "写设计稿")
        try XCTAssertTrue(listed.first?.isOpen == true)
    }

    tests.add("TaskTracker.testAddMultipleTasks") { _ in
        let (tracker, _, _) = makeTracker()
        let t1 = Task(name: "task1")
        let t2 = Task(name: "task2")
        let t3 = Task(name: "task3")
        for t in [t1, t2, t3] {
            try tracker.add(t)
        }
        let listed = try tracker.list(filter: .all)
        try XCTAssertEqual(listed.count, 3)
        // list 应按 createdAt 升序
        try XCTAssertEqual(listed.map(\.name), ["task1", "task2", "task3"])
    }

    // MARK: - complete

    tests.add("TaskTracker.testCompleteWritesMemoryAndUpdatesTask") { _ in
        let (tracker, mem, router) = makeTracker(petRoot: URL(fileURLWithPath: "/tmp"))
        let task = Task(name: "写代码")
        try tracker.add(task)
        let initialState = router?.currentState ?? .idle
        let memory = try tracker.complete(id: task.id)
        try XCTAssertEqual(memory.type, .task)
        try XCTAssertEqual(memory.petID, "pet_test")
        try XCTAssertEqual(memory.metadata["task_name"], "写代码")

        // task 文件更新：completedAt 不为 nil
        let listed = try tracker.list(filter: .completed)
        try XCTAssertEqual(listed.count, 1)
        try XCTAssertTrue(listed.first?.completedAt != nil)

        // memory 写到 disk
        let loaded = try mem.load(forPetID: "pet_test")
        try XCTAssertEqual(loaded.count, 1)
        try XCTAssertEqual(loaded.first?.type, .task)

        // router 触发 taskDone → celebrate
        if let r = router {
            try XCTAssertEqual(r.currentState, .celebrate)
            _ = initialState  // silence unused warning
        }
    }

    tests.add("TaskTracker.testCompleteUnknownIdThrows") { _ in
        let (tracker, _, _) = makeTracker()
        let fakeID = UUID()
        try XCTAssertThrowsError({ _ = try tracker.complete(id: fakeID) })
    }

    tests.add("TaskTracker.testCompleteTwiceThrows") { _ in
        let (tracker, _, _) = makeTracker()
        let task = Task(name: "task")
        try tracker.add(task)
        _ = try tracker.complete(id: task.id)
        try XCTAssertThrowsError({ _ = try tracker.complete(id: task.id) },
                                  "second complete must throw")
    }

    tests.add("TaskTracker.testCompleteAfterAbandonThrows") { _ in
        let (tracker, _, _) = makeTracker()
        let task = Task(name: "task")
        try tracker.add(task)
        try tracker.abandon(id: task.id)
        try XCTAssertThrowsError({ _ = try tracker.complete(id: task.id) },
                                  "complete after abandon must throw")
    }

    // MARK: - abandon

    tests.add("TaskTracker.testAbandonMarksTaskAndDoesNotWriteMemory") { _ in
        let (tracker, mem, _) = makeTracker()
        let task = Task(name: "写邮件")
        try tracker.add(task)
        try tracker.abandon(id: task.id)

        let abandoned = try tracker.list(filter: .abandoned)
        try XCTAssertEqual(abandoned.count, 1)
        try XCTAssertTrue(abandoned.first?.abandonedAt != nil)

        // 不写 memory
        let loaded = try mem.load(forPetID: "pet_test")
        try XCTAssertEqual(loaded.count, 0, "abandon must not write any memory")
    }

    tests.add("TaskTracker.testAbandonUnknownIdThrows") { _ in
        let (tracker, _, _) = makeTracker()
        try XCTAssertThrowsError({ try tracker.abandon(id: UUID()) })
    }

    tests.add("TaskTracker.testAbandonTwiceThrows") { _ in
        let (tracker, _, _) = makeTracker()
        let task = Task(name: "task")
        try tracker.add(task)
        try tracker.abandon(id: task.id)
        try XCTAssertThrowsError({ try tracker.abandon(id: task.id) })
    }

    // MARK: - list filters

    tests.add("TaskTracker.testListFilters") { _ in
        let (tracker, _, _) = makeTracker()
        let t1 = Task(name: "open1")
        let t2 = Task(name: "completed")
        let t3 = Task(name: "abandoned")
        for t in [t1, t2, t3] {
            try tracker.add(t)
        }
        _ = try tracker.complete(id: t2.id)
        try tracker.abandon(id: t3.id)

        let open = try tracker.list(filter: .open)
        let completed = try tracker.list(filter: .completed)
        let abandoned = try tracker.list(filter: .abandoned)
        let all = try tracker.list(filter: .all)
        try XCTAssertEqual(open.count, 1)
        try XCTAssertEqual(open.first?.name, "open1")
        try XCTAssertEqual(completed.count, 1)
        try XCTAssertEqual(completed.first?.name, "completed")
        try XCTAssertEqual(abandoned.count, 1)
        try XCTAssertEqual(abandoned.first?.name, "abandoned")
        try XCTAssertEqual(all.count, 3)
    }

    // MARK: - 持久化跨实例

    tests.add("TaskTracker.testPersistenceAcrossInstances") { _ in
        let taskRoot = makeTmpRoot("persist")
        let memRoot = makeTmpRoot("persist-mem")
        let memStore1 = MemoryStore(root: memRoot)

        // instance 1: add + complete
        let t1 = Task(name: "persist task")
        do {
            let tracker1 = TaskTracker(root: taskRoot, memoryStore: memStore1)
            tracker1.petID = "pet_test"
            tracker1.petName = "TestPet"
            try tracker1.add(t1)
            _ = try tracker1.complete(id: t1.id)
        }

        // instance 2: 新 MemoryStore + 新 TaskTracker（同一 root）
        let memStore2 = MemoryStore(root: memRoot)
        let tracker2 = TaskTracker(root: taskRoot, memoryStore: memStore2)
        tracker2.petID = "pet_test"
        tracker2.petName = "TestPet"

        let listed = try tracker2.list(filter: .all)
        try XCTAssertEqual(listed.count, 1)
        try XCTAssertEqual(listed.first?.name, "persist task")
        try XCTAssertTrue(listed.first?.isCompleted == true, "task should be marked completed across instances")

        // memory 也跨实例持久化
        let loaded = try memStore2.load(forPetID: "pet_test")
        try XCTAssertEqual(loaded.count, 1)
        try XCTAssertEqual(loaded.first?.type, .task)
    }

    // MARK: - router 集成

    tests.add("TaskTracker.testCompleteTriggersRouterTaskDone") { _ in
        let (tracker, _, router) = makeTracker(petRoot: URL(fileURLWithPath: "/tmp"))
        let task = Task(name: "t")
        try tracker.add(task)
        let r = try XCTUnwrap(router)
        try XCTAssertEqual(r.currentState, .idle, "initial router state must be .idle")
        _ = try tracker.complete(id: task.id)
        try XCTAssertEqual(r.currentState, .celebrate, "complete must trigger .taskDone → celebrate")
    }

    tests.add("TaskTracker.testAbandonDoesNotTriggerRouter") { _ in
        let (tracker, _, router) = makeTracker(petRoot: URL(fileURLWithPath: "/tmp"))
        let task = Task(name: "t")
        try tracker.add(task)
        let r = try XCTUnwrap(router)
        try session_abandon_helper(tracker: tracker, taskID: task.id, router: r)
    }

    // MARK: - memory 写盘失败 → throw

    tests.add("TaskTracker.testCompleteMemoryWriteFailureThrows") { _ in
        // 用 readonly memory root
        let memRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-mem-readonly-\(UUID().uuidString)", isDirectory: true)
        try "x".write(to: memRoot, atomically: true, encoding: .utf8)
        let memStore = MemoryStore(root: memRoot)
        let taskRoot = makeTmpRoot("mem-fail")
        let tracker = TaskTracker(root: taskRoot, memoryStore: memStore)
        tracker.petID = "pet_test"
        tracker.petName = "TestPet"
        let task = Task(name: "t")
        try tracker.add(task)
        let memory: SharedMemory? = try? tracker.complete(id: task.id)
        try XCTAssertNil(memory, "complete must throw when memory write fails")
        // task 状态保持 open（没完成）
        let open = try tracker.list(filter: .open)
        try XCTAssertEqual(open.count, 1, "task should remain open when memory write fails")
    }
}

// MARK: - helpers

func session_abandon_helper(tracker: TaskTracker, taskID: UUID, router: PetActionRouter) throws {
    try tracker.abandon(id: taskID)
    try XCTAssertEqual(router.currentState, .idle, "abandon must not trigger taskDone")
    _ = Task.self  // silence unused warning in case
}
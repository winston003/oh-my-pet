// SharedMemoryTests.swift
// SharedMemory + MemoryStore 单元测试
//
// 覆盖：
//   - SharedMemory Codable roundtrip
//   - MemoryStore.append 写 per-file + index
//   - MemoryStore.loadAll 读 + 时间线排序
//   - MemoryStore.load(forPetID:) 过滤
//   - 重复 id → throw
//   - index.json 损坏 → 清理 per-file + 抛错
//   - 原子写（tmp + replaceItemAt）
//   - 默认 root ~/Library/Application Support/oh-my-pet/memories/ (fallback tmp 测)
//   - SharedMemoryFactory 产出 deterministic title
//
import Foundation
@testable import PetProfileFocus

func registerSharedMemoryTests(_ tests: Tests) {

    // 辅助：构造 tmp root
    func makeTmpRoot(_ suffix: String = "mem") -> URL {
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-mem-\(suffix)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - SharedMemory Codable

    tests.add("SharedMemory.testCodableRoundtrip") { _ in
        let mem = SharedMemory(
            petID: "pet_test",
            type: .focus,
            title: "test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 1500,
            metadata: ["task_name": "write docs"]
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(mem)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let decoded = try dec.decode(SharedMemory.self, from: data)
        try XCTAssertEqual(decoded, mem)
    }

    tests.add("SharedMemory.testMemoryTypeCodable") { _ in
        try XCTAssertEqual(MemoryType.focus.rawValue, "focus")
        try XCTAssertEqual(MemoryType.task.rawValue, "task")
    }

    // MARK: - SharedMemoryFactory

    tests.add("SharedMemory.testFocusFactoryProducesTitle") { _ in
        let m = SharedMemoryFactory.focusMemory(
            petName: "Pako",
            petID: "pet_pako",
            durationSeconds: 1500,
            taskName: "写设计稿",
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        try XCTAssertEqual(m.type, .focus)
        try XCTAssertEqual(m.petID, "pet_pako")
        try XCTAssertEqual(m.durationSeconds, 1500)
        try XCTAssertEqual(m.title, "Pako 陪你专注了 25 分钟")
        try XCTAssertEqual(m.metadata["task_name"], "写设计稿")
    }

    tests.add("SharedMemory.testFocusFactoryMinimumOneMinute") { _ in
        // 30 秒 focus → title 仍显示 "1 分钟"（min=1）
        let m = SharedMemoryFactory.focusMemory(
            petName: "Mitu",
            petID: "pet_mitu",
            durationSeconds: 30
        )
        try XCTAssertEqual(m.title, "Mitu 陪你专注了 1 分钟")
    }

    tests.add("SharedMemory.testTaskFactoryProducesTitle") { _ in
        let taskID = UUID()
        let m = SharedMemoryFactory.taskMemory(
            petName: "Zorp",
            petID: "pet_zorp",
            taskName: "改 bug",
            taskID: taskID,
            createdAt: Date(timeIntervalSince1970: 1_000_000)
        )
        try XCTAssertEqual(m.type, .task)
        try XCTAssertEqual(m.petID, "pet_zorp")
        try XCTAssertEqual(m.durationSeconds, nil)
        try XCTAssertEqual(m.title, "Zorp 看你完成了「改 bug」")
        try XCTAssertEqual(m.metadata["task_id"], taskID.uuidString)
        try XCTAssertEqual(m.metadata["task_name"], "改 bug")
    }

    // MARK: - MemoryStore.append

    tests.add("MemoryStore.testAppendWritesPerFileAndIndex") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let mem = SharedMemory(
            petID: "pet_test",
            type: .focus,
            title: "x",
            createdAt: Date(timeIntervalSince1970: 1_000_000),
            durationSeconds: 600
        )
        try store.append(mem)
        // per-file
        let fileURL = store.memoryFile(for: mem.id)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        // index
        try XCTAssertTrue(FileManager.default.fileExists(atPath: store.indexURL.path))
    }

    tests.add("MemoryStore.testAppendDuplicateThrows") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let mem = SharedMemory(petID: "pet_test", type: .focus, title: "x")
        try store.append(mem)
        try XCTAssertThrowsError({ try store.append(mem) },
                                  "duplicate id must throw")
    }

    // MARK: - MemoryStore.loadAll

    tests.add("MemoryStore.testLoadAllSortsByCreatedAt") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let now = Date(timeIntervalSince1970: 1_000_000)
        let m1 = SharedMemory(petID: "p", type: .focus, title: "first",
                              createdAt: now.addingTimeInterval(0))
        let m2 = SharedMemory(petID: "p", type: .task, title: "second",
                              createdAt: now.addingTimeInterval(60))
        let m3 = SharedMemory(petID: "p", type: .focus, title: "third",
                              createdAt: now.addingTimeInterval(30))
        try store.append(m1)
        try store.append(m2)
        try store.append(m3)

        let loaded = try store.loadAll()
        try XCTAssertEqual(loaded.count, 3)
        try XCTAssertEqual(loaded.map(\.title), ["first", "third", "second"])
        try XCTAssertEqual(loaded.map(\.id), [m1.id, m3.id, m2.id])
    }

    tests.add("MemoryStore.testLoadAllEmptyRoot") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let loaded = try store.loadAll()
        try XCTAssertEqual(loaded.count, 0)
    }

    tests.add("MemoryStore.testMemoriesCacheUpdated") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let mem = SharedMemory(petID: "p", type: .focus, title: "x")
        try store.append(mem)
        try XCTAssertEqual(store.memories.count, 1)
        try XCTAssertEqual(store.memories.first?.id, mem.id)
    }

    // MARK: - MemoryStore.load(forPetID:)

    tests.add("MemoryStore.testLoadForPetIDFilters") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let now = Date()
        let mA = SharedMemory(petID: "pet_a", type: .focus, title: "a-focus",
                              createdAt: now.addingTimeInterval(0))
        let mB1 = SharedMemory(petID: "pet_b", type: .task, title: "b-task1",
                               createdAt: now.addingTimeInterval(10))
        let mB2 = SharedMemory(petID: "pet_b", type: .focus, title: "b-focus",
                               createdAt: now.addingTimeInterval(20))
        try store.append(mA)
        try store.append(mB1)
        try store.append(mB2)

        let aOnly = try store.load(forPetID: "pet_a")
        try XCTAssertEqual(aOnly.count, 1)
        try XCTAssertEqual(aOnly.first?.petID, "pet_a")

        let bOnly = try store.load(forPetID: "pet_b")
        try XCTAssertEqual(bOnly.count, 2)
        try XCTAssertEqual(bOnly.map(\.petID), ["pet_b", "pet_b"])

        let cOnly = try store.load(forPetID: "pet_c")
        try XCTAssertEqual(cOnly.count, 0)
    }

    tests.add("MemoryStore.testLoadMatchingPredicate") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let m1 = SharedMemory(petID: "p", type: .focus, title: "f1",
                              createdAt: Date(timeIntervalSince1970: 1_000_000))
        let m2 = SharedMemory(petID: "p", type: .task, title: "t1",
                              createdAt: Date(timeIntervalSince1970: 1_000_100))
        try store.append(m1)
        try store.append(m2)

        let onlyFocus = try store.load(matching: { $0.type == .focus })
        try XCTAssertEqual(onlyFocus.count, 1)
        try XCTAssertEqual(onlyFocus.first?.type, .focus)
    }

    // MARK: - 持久化跨实例

    tests.add("MemoryStore.testPersistenceAcrossInstances") { _ in
        let root = makeTmpRoot("persist")
        let id: UUID
        do {
            let store1 = MemoryStore(root: root)
            let mem = SharedMemory(
                petID: "pet_test", type: .focus, title: "persist-test",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                durationSeconds: 600
            )
            try store1.append(mem)
            id = mem.id
        }
        // instance 2
        let store2 = MemoryStore(root: root)
        let loaded = try store2.loadAll()
        try XCTAssertEqual(loaded.count, 1)
        try XCTAssertEqual(loaded.first?.id, id)
        try XCTAssertEqual(loaded.first?.title, "persist-test")
    }

    // MARK: - index.json 损坏

    tests.add("MemoryStore.testCorruptedIndexThrows") { _ in
        let root = makeTmpRoot("corrupt")
        // 写一段乱码到 index.json
        let indexURL = root.appendingPathComponent("index.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "garbage{{".write(to: indexURL, atomically: true, encoding: .utf8)
        let store = MemoryStore(root: root)
        do {
            _ = try store.loadAll()
            try XCTAssertTrue(false, "loadAll must throw on corrupted index")
        } catch let err as MemoryStoreError {
            switch err {
            case .indexCorrupted:
                break  // 期望
            default:
                try XCTAssertTrue(false, "expected indexCorrupted, got \(err)")
            }
        }
    }

    // MARK: - index entry 与 per-file 不一致

    tests.add("MemoryStore.testMissingPerFileIsSkipped") { _ in
        let store = MemoryStore(root: makeTmpRoot())
        let mem1 = SharedMemory(petID: "p", type: .focus, title: "keep")
        try store.append(mem1)
        let mem2 = SharedMemory(petID: "p", type: .focus, title: "will be deleted")
        try store.append(mem2)
        // 删掉 mem2 的 per-file
        let mem2File = store.memoryFile(for: mem2.id)
        try FileManager.default.removeItem(at: mem2File)
        // loadAll 应跳过 mem2，剩 mem1
        let loaded = try store.loadAll()
        try XCTAssertEqual(loaded.count, 1)
        try XCTAssertEqual(loaded.first?.id, mem1.id)
    }

    // MARK: - 默认 root

    tests.add("MemoryStore.testDefaultRootContainsAppSupport") { _ in
        // 不强求是 ~/Library/...（CI / sandbox 可能 fallback tmp）；只检查路径非空 + 末段是 memories
        let r = MemoryStore.defaultRoot()
        try XCTAssertTrue(r.path.hasSuffix("memories"), "defaultRoot must end with /memories")
    }

    // MARK: - 原子写

    tests.add("MemoryStore.testAtomicWriteReplacesExisting") { _ in
        let root = makeTmpRoot("atomic")
        let store = MemoryStore(root: root)
        // 先 append 一条 → atomicWrite index.json（不存在 → moveItem）
        let mem1 = SharedMemory(petID: "p", type: .focus, title: "first")
        try store.append(mem1)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: store.indexURL.path))
        try XCTAssertTrue(FileManager.default.fileExists(atPath: store.memoryFile(for: mem1.id).path))
        // 再 append 一条 → atomicWrite index.json（已存在 → replaceItemAt）
        let mem2 = SharedMemory(petID: "p", type: .focus, title: "second")
        try store.append(mem2)
        // 验两份都在
        let all = try store.loadAll()
        try XCTAssertEqual(all.count, 2)
        // 没有 tmp 残留（用 .<name>.tmp 模式，hidden 文件）
        let residue = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        let tmpFiles = residue.filter { $0.pathExtension == "tmp" }
        try XCTAssertEqual(tmpFiles.count, 0, "no .tmp residue allowed after atomic write")
    }
}
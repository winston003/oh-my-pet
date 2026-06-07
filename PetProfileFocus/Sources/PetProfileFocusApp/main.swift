// main.swift
// PetProfileFocusApp — 命令行入口（端到端 demo：focus + task）
//
// 行为：
//   1. 跑完整 focus 流程：start focus → 25 min（mock）→ complete → verify memory 写到 disk
//   2. 跑完整 task 流程：add 3 tasks → complete 2 → abandon 1 → verify memory + task state
//   3. 端到端：调 PetProfileLoader 加载 Pako fixture → 用 PetActionRouter 集成 → 走 PetStore
//      验证 MemoryStore 跟 PetStore 不互相干扰
//
// 用法：
//   swift run PetProfileFocusApp
//
// Exit code:
//   0 = success
//   1 = failure
//
// 不做：
//   - 不跑 NSApp.run()
//   - 不接真 LLM
//   - 不实现 daily ritual
//
import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileStudio
import PetProfileFocus

// 触发 AppKit 类型检查
_ = NSApplication.self

func printBanner(_ msg: String) {
    print("[focus] \(msg)")
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("[focus] FAIL: \(msg)\n".utf8))
    exit(1)
}

// MARK: - 用 tmp 目录隔离（避免污染真 ~/Library）

let tmpMemRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("oh-my-pet-focus-mem-\(UUID().uuidString.prefix(8))", isDirectory: true)
let tmpTaskRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("oh-my-pet-focus-task-\(UUID().uuidString.prefix(8))", isDirectory: true)
let tmpPetRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("oh-my-pet-focus-pet-\(UUID().uuidString.prefix(8))", isDirectory: true)

let memoryStore = MemoryStore(root: tmpMemRoot)
let taskTracker = TaskTracker(root: tmpTaskRoot, memoryStore: memoryStore)
let petStore = PetStore(root: tmpPetRoot)

printBanner("tmp roots:")
printBanner("  memory: \(tmpMemRoot.path)")
printBanner("  task:   \(tmpTaskRoot.path)")
printBanner("  pet:    \(tmpPetRoot.path)")

// MARK: - 加载 Pako fixture + 构造 PetActionRouter

let fixtureRoot = "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
let pakoManifest = URL(fileURLWithPath: "\(fixtureRoot)/pako-v1.0.0.json")
let loader = PetProfileLoader()
let pakoProfile: LoadedPetProfile
do {
    pakoProfile = try loader.loadProfile(from: pakoManifest)
} catch {
    fail("load Pako fixture failed: \(error)")
}
let pakoPetID = pakoProfile.manifest.id.raw
let pakoPetName = pakoProfile.manifest.name
printBanner("loaded Pako: \(pakoPetName) (\(pakoPetID))")

let panel = PetPanel(profile: pakoProfile)
let router = PetActionRouter(profile: pakoProfile, panel: panel)
let focusSession = FocusSession(memoryStore: memoryStore)
focusSession.router = router
focusSession.petID = pakoPetID
focusSession.petName = pakoPetName
taskTracker.router = router
taskTracker.petID = pakoPetID
taskTracker.petName = pakoPetName

// MARK: - 1. Focus 流程

printBanner("=== focus flow ===")

let focusStartTime = Date()
do {
    try focusSession.start()
    printBanner("[OK] focus start: state=\(focusSession.state.rawValue), router.currentState=\(router.currentState.rawValue)")
} catch {
    fail("focus start failed: \(error)")
}
guard focusSession.state == .focusing else {
    fail("state must be .focusing after start")
}
guard router.currentState == .focus else {
    fail("router.currentState must be .focus after start")
}

// 25-min focus (mock — 1.5 秒 wall-clock)
Thread.sleep(forTimeInterval: 1.5)
do {
    let memory = try focusSession.complete()
    printBanner("[OK] focus complete: duration=\(focusSession.totalSeconds)s")
    printBanner("     memory: \(memory.title) (id=\(memory.id.uuidString.prefix(8))…)")
} catch {
    fail("focus complete failed: \(error)")
}
guard focusSession.state == .completed else {
    fail("state must be .completed after complete()")
}
guard router.currentState == .celebrate else {
    fail("router.currentState must be .celebrate after complete (taskDone event)")
}

// 验 memory 写到 disk
do {
    let loaded = try memoryStore.load(forPetID: pakoPetID)
    guard loaded.count == 1 else {
        fail("expected 1 memory for Pako, got \(loaded.count)")
    }
    let mem = loaded[0]
    guard mem.type == .focus else {
        fail("memory type must be .focus, got \(mem.type.rawValue)")
    }
    printBanner("[OK] memory on disk: type=\(mem.type.rawValue), title=\"\(mem.title)\"")
} catch {
    fail("memory load failed: \(error)")
}

// reset 给下一段（demo 用）
focusSession.reset()
guard focusSession.state == .idle else {
    fail("state must be .idle after reset()")
}

_ = focusStartTime  // 避免 unused warning

// MARK: - 2. Task 流程

printBanner("=== task flow ===")

let task1 = Task(name: "写设计稿")
let task2 = Task(name: "改 bug")
let task3 = Task(name: "回邮件")
for t in [task1, task2, task3] {
    do {
        try taskTracker.add(t)
        printBanner("[OK] add task: \(t.name) (\(t.id.uuidString.prefix(8))…)")
    } catch {
        fail("add task failed: \(error)")
    }
}

var listed = try taskTracker.list(filter: .open)
guard listed.count == 3 else {
    fail("expected 3 open tasks, got \(listed.count)")
}
printBanner("[OK] list(open) = 3 tasks")

// complete 2
do {
    _ = try taskTracker.complete(id: task1.id)
    printBanner("[OK] complete: \(task1.name)")
} catch {
    fail("complete task1 failed: \(error)")
}
do {
    _ = try taskTracker.complete(id: task2.id)
    printBanner("[OK] complete: \(task2.name)")
} catch {
    fail("complete task2 failed: \(error)")
}

// abandon 1
do {
    try taskTracker.abandon(id: task3.id)
    printBanner("[OK] abandon: \(task3.name)")
} catch {
    fail("abandon task3 failed: \(error)")
}

listed = try taskTracker.list(filter: .open)
guard listed.count == 0 else {
    fail("expected 0 open tasks, got \(listed.count)")
}
listed = try taskTracker.list(filter: .completed)
guard listed.count == 2 else {
    fail("expected 2 completed tasks, got \(listed.count)")
}
listed = try taskTracker.list(filter: .abandoned)
guard listed.count == 1 else {
    fail("expected 1 abandoned task, got \(listed.count)")
}
printBanner("[OK] list filter: 0 open / 2 completed / 1 abandoned")

// verify memory: 1 focus + 2 task = 3 total
do {
    let memories = try memoryStore.load(forPetID: pakoPetID)
    guard memories.count == 3 else {
        fail("expected 3 memories for Pako (1 focus + 2 task), got \(memories.count)")
    }
    let focusCount = memories.filter { $0.type == .focus }.count
    let taskCount = memories.filter { $0.type == .task }.count
    guard focusCount == 1 && taskCount == 2 else {
        fail("memory breakdown wrong: focus=\(focusCount), task=\(taskCount)")
    }
    printBanner("[OK] memories on disk: 1 focus + 2 task = 3 total")
} catch {
    fail("memory load failed: \(error)")
}

// MARK: - 3. PetProfileStudio 集成

printBanner("=== PetProfileStudio integration ===")

// 3a. PetStore 单独跑 CRUD（不互相干扰）
let initial = try petStore.loadAll()
guard initial.isEmpty else {
    fail("expected 0 pets in fresh tmp root, got \(initial.count)")
}
printBanner("[OK] PetStore.loadAll() = 0 (no interference)")

// 3b. PetHouseMemoryBridge: SharedMemory → PetMemory
do {
    let petMemories = try PetHouseMemoryBridge.petMemories(petID: pakoPetID, store: memoryStore)
    guard petMemories.count == 3 else {
        fail("PetHouseMemoryBridge: expected 3 PetMemory, got \(petMemories.count)")
    }
    let focusKind = petMemories.filter { $0.kind == .focusComplete }.count
    let taskKind = petMemories.filter { $0.kind == .taskComplete }.count
    guard focusKind == 1 && taskKind == 2 else {
        fail("PetMemory breakdown wrong: focusComplete=\(focusKind), taskComplete=\(taskKind)")
    }
    printBanner("[OK] PetHouseMemoryBridge: 3 PetMemory (1 focusComplete + 2 taskComplete)")
} catch {
    fail("PetHouseMemoryBridge failed: \(error)")
}

// MARK: - 退出

printBanner("[OK] PetProfileFocusApp: focus + task + PetHouseMemoryBridge 全过；exit 0")
exit(0)
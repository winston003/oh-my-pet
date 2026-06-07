// TaskTracker.swift
// TaskTracker — 任务 CRUD + 持久化 + 跟 FocusSession 联动 + 写 shared memory
//
// 责任：
//   - 增删查改 task：add / complete / abandon / list
//   - 持久化到 `~/Library/Application Support/oh-my-pet/tasks/<id>.json` + `index.json`
//   - complete → 写 task memory + 触发 PetActionRouter.taskDone event
//   - abandon → 不写 memory（不算完成）
//
// 设计决策：
//   - **结构跟 MemoryStore 对齐**：per-task 文件 + index.json；原子写。
//   - **filter 走 enum**：open (open + 非 abandoned) / completed / abandoned / all
//   - **FocusSession 联动**：TaskTracker 内部 **不** 直接持有 FocusSession 引用。
//     complete() 时如果 caller 注入了 router，就发 .taskDone 让 pet 切到 celebrate。
//     FocusSession 跟 TaskTracker 互不感知（避免循环依赖）。
//   - **task 命名**：单一 name 字段；不做 description / priority / deadline（属 P2-H）
//   - **完成时间**：completedAt；abandonedAt；二选一；都 nil 表示 open
//
// 不做：
//   - 不并发（v1 单线程）
//   - 不写 focus memory（focus 走 FocusSession）
//   - 不做任务依赖 / 子任务
//
import Foundation
import Combine
import PetProfileRuntime

// MARK: - Task

public struct Task: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var completedAt: Date?
    public var abandonedAt: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        completedAt: Date? = nil,
        abandonedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.abandonedAt = abandonedAt
    }

    public var isOpen: Bool {
        completedAt == nil && abandonedAt == nil
    }
    public var isCompleted: Bool {
        completedAt != nil
    }
    public var isAbandoned: Bool {
        abandonedAt != nil
    }
}

// MARK: - Filter

public enum TaskFilter: Equatable {
    case all
    case open          // 包含 open（completedAt == nil && abandonedAt == nil）
    case completed     // completedAt != nil
    case abandoned     // abandonedAt != nil
}

// MARK: - Errors

public enum TaskTrackerError: Error, CustomStringConvertible, Equatable {
    case taskNotFound(id: String)
    case alreadyCompleted(id: String)
    case alreadyAbandoned(id: String)
    case memoryWriteFailed(reason: String)

    public var description: String {
        switch self {
        case .taskNotFound(let id):
            return "TaskTracker: task not found — \(id)"
        case .alreadyCompleted(let id):
            return "TaskTracker: task already completed — \(id)"
        case .alreadyAbandoned(let id):
            return "TaskTracker: task already abandoned — \(id)"
        case .memoryWriteFailed(let r):
            return "TaskTracker: memory write failed — \(r)"
        }
    }
}

// MARK: - TaskIndexEntry

/// index.json 里每条 task 的精简 metadata（避免重复读全文）
struct TaskIndexEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let createdAt: Date
    let completedAt: Date?
    let abandonedAt: Date?

    init(from task: Task) {
        self.id = task.id
        self.name = task.name
        self.createdAt = task.createdAt
        self.completedAt = task.completedAt
        self.abandonedAt = task.abandonedAt
    }

    init(
        id: UUID,
        name: String,
        createdAt: Date,
        completedAt: Date?,
        abandonedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.abandonedAt = abandonedAt
    }
}

// MARK: - TaskTracker

public final class TaskTracker: ObservableObject {

    public enum State: String, Codable, Equatable, Sendable, CaseIterable {
        case open
        case completed
        case abandoned
    }

    @Published public private(set) var tasks: [Task] = []

    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// 持久化根目录；默认 ~/Library/Application Support/oh-my-pet/tasks/
    public let root: URL
    private let memoryStore: MemoryStore
    /// 可选：触发 .taskDone 让 pet celebrate
    public weak var router: PetActionRouter?
    /// 关联 pet id（写 memory 用）
    public var petID: String?
    /// 关联 pet 展示名（写 memory title 用）
    public var petName: String?

    // MARK: - Init

    public init(
        root: URL = TaskTracker.defaultRoot(),
        memoryStore: MemoryStore = .shared
    ) {
        self.root = root
        self.memoryStore = memoryStore
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - 默认 root

    public static func defaultRoot() -> URL {
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport
                .appendingPathComponent("oh-my-pet", isDirectory: true)
                .appendingPathComponent("tasks", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-pet-fallback", isDirectory: true)
            .appendingPathComponent("tasks", isDirectory: true)
    }

    /// 给定 task id 的 per-file URL
    public func taskFile(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// index.json 路径
    public var indexURL: URL {
        root.appendingPathComponent("index.json", isDirectory: false)
    }

    // MARK: - CRUD

    /// 新增 task。
    public func add(_ task: Task) throws {
        try ensureRootDirectory()

        let fileURL = taskFile(for: task.id)
        if fm.fileExists(atPath: fileURL.path) {
            throw TaskTrackerError.taskNotFound(id: task.id.uuidString + " (duplicate)")
        }

        // 1. 写 per-task 文件
        let data = try encoder.encode(task)
        try atomicWrite(data: data, to: fileURL)

        // 2. 更新 index.json
        let indexURL = self.indexURL
        var entries: [TaskIndexEntry] = []
        if fm.fileExists(atPath: indexURL.path) {
            let indexData = try Data(contentsOf: indexURL)
            entries = (try? decoder.decode([TaskIndexEntry].self, from: indexData)) ?? []
        }
        entries.append(TaskIndexEntry(from: task))
        let indexData = try encoder.encode(entries)
        try atomicWrite(data: indexData, to: indexURL)

        tasks.append(task)
    }

    /// 完成 task：写 task memory + router.taskDone + 持久化。
    /// - Returns: 写入的 SharedMemory
    /// - Throws: task 不存在 / 已经是 completed / 已经是 abandoned / 写盘失败
    public func complete(id: UUID) throws -> SharedMemory {
        try ensureRootDirectory()
        let fileURL = taskFile(for: id)
        guard fm.fileExists(atPath: fileURL.path) else {
            throw TaskTrackerError.taskNotFound(id: id.uuidString)
        }
        let data = try Data(contentsOf: fileURL)
        var task = try decoder.decode(Task.self, from: data)

        if task.completedAt != nil {
            throw TaskTrackerError.alreadyCompleted(id: id.uuidString)
        }
        if task.abandonedAt != nil {
            throw TaskTrackerError.alreadyAbandoned(id: id.uuidString)
        }

        let now = clock()
        task.completedAt = now

        // 写 task memory
        let petID = self.petID ?? "unknown_pet"
        let petName = self.petName ?? "Pet"
        let memory: SharedMemory
        do {
            memory = SharedMemoryFactory.taskMemory(
                petName: petName,
                petID: petID,
                taskName: task.name,
                taskID: task.id,
                createdAt: now
            )
            try memoryStore.append(memory)
        } catch {
            throw TaskTrackerError.memoryWriteFailed(reason: "\(error)")
        }

        // 持久化 task 更新
        let updatedData = try encoder.encode(task)
        try atomicWrite(data: updatedData, to: fileURL)
        // 同步 index
        try updateIndexEntry(task)

        // 跟 router 集成：taskDone（pet 切到 celebrate）
        router?.handle(event: .taskDone)

        // 刷 cache
        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
        return memory
    }

    /// 放弃 task：不写 memory，不触发 router。
    public func abandon(id: UUID) throws {
        try ensureRootDirectory()
        let fileURL = taskFile(for: id)
        guard fm.fileExists(atPath: fileURL.path) else {
            throw TaskTrackerError.taskNotFound(id: id.uuidString)
        }
        let data = try Data(contentsOf: fileURL)
        var task = try decoder.decode(Task.self, from: data)

        if task.completedAt != nil {
            throw TaskTrackerError.alreadyCompleted(id: id.uuidString)
        }
        if task.abandonedAt != nil {
            throw TaskTrackerError.alreadyAbandoned(id: id.uuidString)
        }

        task.abandonedAt = clock()
        let updatedData = try encoder.encode(task)
        try atomicWrite(data: updatedData, to: fileURL)
        try updateIndexEntry(task)

        if let idx = tasks.firstIndex(where: { $0.id == id }) {
            tasks[idx] = task
        } else {
            tasks.append(task)
        }
    }

    /// 列出 task（按 createdAt 升序）。
    public func list(filter: TaskFilter = .all) throws -> [Task] {
        // 重新从磁盘读（保证一致性）
        let all = try loadAllFromDisk()
        tasks = all

        switch filter {
        case .all:
            return all
        case .open:
            return all.filter { $0.isOpen }
        case .completed:
            return all.filter { $0.isCompleted }
        case .abandoned:
            return all.filter { $0.isAbandoned }
        }
    }

    /// 强制 reload 内存 cache。
    public func reload() throws {
        tasks = try loadAllFromDisk()
    }

    // MARK: - 维护

    /// 确保 root 目录存在。
    public func ensureRootDirectory() throws {
        if !fm.fileExists(atPath: root.path) {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw TaskTrackerError.taskNotFound(id: "root creation: \(error)")
            }
        }
    }

    // MARK: - 私有

    private var clock: () -> Date { { Date() } }

    private func loadAllFromDisk() throws -> [Task] {
        try ensureRootDirectory()
        let indexURL = self.indexURL
        guard fm.fileExists(atPath: indexURL.path) else {
            return []
        }
        let indexData = try Data(contentsOf: indexURL)
        let entries = try decoder.decode([TaskIndexEntry].self, from: indexData)

        var loaded: [Task] = []
        loaded.reserveCapacity(entries.count)
        for entry in entries {
            let fileURL = taskFile(for: entry.id)
            guard fm.fileExists(atPath: fileURL.path) else { continue }
            do {
                let data = try Data(contentsOf: fileURL)
                let task = try decoder.decode(Task.self, from: data)
                loaded.append(task)
            } catch {
                continue
            }
        }
        loaded.sort { $0.createdAt < $1.createdAt }
        return loaded
    }

    private func updateIndexEntry(_ task: Task) throws {
        let indexURL = self.indexURL
        var entries: [TaskIndexEntry] = []
        if fm.fileExists(atPath: indexURL.path) {
            let indexData = try Data(contentsOf: indexURL)
            entries = (try? decoder.decode([TaskIndexEntry].self, from: indexData)) ?? []
        }
        // 找到同 id 的 entry 替换；找不到就追加
        var found = false
        for (i, e) in entries.enumerated() where e.id == task.id {
            entries[i] = TaskIndexEntry(from: task)
            found = true
            break
        }
        if !found {
            entries.append(TaskIndexEntry(from: task))
        }
        let indexData = try encoder.encode(entries)
        try atomicWrite(data: indexData, to: indexURL)
    }

    private func atomicWrite(data: Data, to url: URL) throws {
        var tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        if fm.fileExists(atPath: tmp.path) {
            tmp = tmp.deletingPathExtension()
                .appendingPathExtension(UUID().uuidString + ".tmp")
        }
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? fm.removeItem(at: tmp)
            throw error
        }
    }
}
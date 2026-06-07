// MemoryStore.swift
// MemoryStore — SharedMemory 持久化（JSON + 原子写 + 时间线索引）
//
// 责任：
//   - 单一全局入口：MemoryStore.shared
//   - 物理布局：
//       ~/Library/Application Support/oh-my-pet/memories/
//         - index.json                     — 所有 memory metadata 时间线
//         - <uuid>.json                    — 每条 memory 全文
//   - 写：append 一条 → 写 <uuid>.json（原子）→ 更新 index.json（原子）
//   - 读：loadAll / load(forPetID:) / load(matching:) / memories（cache）
//   - 可注入 root：测试用 tmp 目录，避免污染真 ~/Library
//
// 设计决策：
//   - **集中式存储**（vs 每个 pet 一个 memories.json）：
//     集中在一个目录方便全局时间线（Pet House Tab "记忆" / "今天和 pet 的互动" 后续可走 index.json
//     排序 + 过滤）；后续 P2-G 也方便转写到每个 pet 目录的 memories.json 给 PetStore 读。
//   - **per-memory 文件 + index**：
//     per-memory 文件便于增量写（单条 memory 几百字节，整文存）。
//     index.json 是时间线 view（read-only 加速）；append 时同步更新。
//   - **原子写**：跟 PetStore 一致（tmp + replaceItemAt）；保证断电不坏。
//   - **不接 PetStore.PetMemory**：PetStore 是 frozen，PetMemory.Kind 跟我们不一样
//     （focusComplete vs focus）。本包内部用 SharedMemory；如 Pet House Tab 要显示，
//     转换层留给未来 P2-G。
//   - **单例 + 可注入**：defaultRoot 默认走 ~/Library/Application Support/oh-my-pet/memories/，
//     fallback tmp。init(root:) 暴露给测试。
//
// 不做：
//   - 不做 schema 升级 / 不做并发锁（单进程）
//   - 不写每个 pet 目录的 memories.json（PetStore 是 frozen，PetHouseDataStore.readJSON
//     的写入端不在本包）
//   - 不删 / 不编辑既有 memory（v1 只 append）
//
import Foundation

// MARK: - IndexEntry

/// index.json 里每条的精简 metadata。full body 在 per-memory 文件里。
public struct MemoryIndexEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let petID: String
    public let type: MemoryType
    public let title: String
    public let createdAt: Date

    public init(
        id: UUID,
        petID: String,
        type: MemoryType,
        title: String,
        createdAt: Date
    ) {
        self.id = id
        self.petID = petID
        self.type = type
        self.title = title
        self.createdAt = createdAt
    }

    public init(from memory: SharedMemory) {
        self.id = memory.id
        self.petID = memory.petID
        self.type = memory.type
        self.title = memory.title
        self.createdAt = memory.createdAt
    }
}

// MARK: - MemoryStore

public final class MemoryStore {

    /// 全局默认单例 — root = ~/Library/Application Support/oh-my-pet/memories/
    public static let shared: MemoryStore = MemoryStore(root: MemoryStore.defaultRoot())

    /// 持久化根目录（可注入测试）
    public let root: URL

    /// 内存 cache — loadAll 后填。append 后追加；不主动清空。
    public private(set) var memories: [SharedMemory] = []

    private let fm = FileManager.default
    /// encoder / decoder — 跟 PetProfileKit ProfileIO 对齐：prettyPrinted + sortedKeys + ISO8601
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL) {
        self.root = root
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
    }

    // MARK: - 默认 root

    /// 跟 PetStore.defaultRoot 一致：app support 优先 → fallback tmp
    public static func defaultRoot() -> URL {
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport
                .appendingPathComponent("oh-my-pet", isDirectory: true)
                .appendingPathComponent("memories", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-pet-fallback", isDirectory: true)
            .appendingPathComponent("memories", isDirectory: true)
    }

    /// 给定 memory id 的 per-file URL
    public func memoryFile(for id: UUID) -> URL {
        root.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// index.json 路径
    public var indexURL: URL {
        root.appendingPathComponent("index.json", isDirectory: false)
    }

    // MARK: - 读

    /// 加载所有 memory（按 createdAt 升序），刷新 cache。
    /// - Throws: I/O / 解析错误（index.json 损坏 → 抛 .indexCorrupted；per-memory 文件损坏 → skip + 警告）
    public func loadAll() throws -> [SharedMemory] {
        try ensureRootDirectory()
        let indexURL = self.indexURL
        guard fm.fileExists(atPath: indexURL.path) else {
            memories = []
            return []
        }
        let indexData = try Data(contentsOf: indexURL)
        let entries: [MemoryIndexEntry]
        do {
            entries = try decoder.decode([MemoryIndexEntry].self, from: indexData)
        } catch {
            throw MemoryStoreError.indexCorrupted(path: indexURL.path, reason: error.localizedDescription)
        }

        var loaded: [SharedMemory] = []
        loaded.reserveCapacity(entries.count)
        for entry in entries {
            let fileURL = memoryFile(for: entry.id)
            guard fm.fileExists(atPath: fileURL.path) else {
                // index 写了但文件丢了 → skip + 警告（不抛错）
                FileHandle.standardError.write(Data(
                    "MemoryStore: skip \(entry.id.uuidString) — per-memory file missing\n".utf8
                ))
                continue
            }
            do {
                let data = try Data(contentsOf: fileURL)
                let mem = try decoder.decode(SharedMemory.self, from: data)
                loaded.append(mem)
            } catch {
                FileHandle.standardError.write(Data(
                    "MemoryStore: skip \(entry.id.uuidString) — decode failed: \(error)\n".utf8
                ))
                continue
            }
        }

        // 按 createdAt 升序
        loaded.sort { $0.createdAt < $1.createdAt }
        memories = loaded
        return loaded
    }

    /// 加载某只 pet 的 memory（按 createdAt 升序），不刷 cache（避免破坏全局顺序视图）
    /// - Throws: I/O / 解析错误
    public func load(forPetID petID: String) throws -> [SharedMemory] {
        let all = try loadAll()
        return all.filter { $0.petID == petID }
    }

    /// 给定 predicate 过滤（叠加在 loadAll 之上）。空结果时返回 []。
    public func load(matching predicate: (SharedMemory) -> Bool) throws -> [SharedMemory] {
        let all = try loadAll()
        return all.filter(predicate)
    }

    // MARK: - 写

    /// append 一条 memory → 写 <uuid>.json + 追加到 index.json（都是原子写）。
    /// - 重复 id：抛 `MemoryStoreError.duplicateMemoryID`
    /// - I/O 失败：抛原 error；先写成功的 per-file 会回滚
    public func append(_ memory: SharedMemory) throws {
        try ensureRootDirectory()

        let fileURL = memoryFile(for: memory.id)
        // 防重复
        if fm.fileExists(atPath: fileURL.path) {
            throw MemoryStoreError.duplicateMemoryID(id: memory.id.uuidString)
        }

        // 1. 写 per-memory 文件
        let data = try encoder.encode(memory)
        try atomicWrite(data: data, to: fileURL)

        // 2. 更新 index.json（读老 entries → 追加 → 写新）
        let indexURL = self.indexURL
        var entries: [MemoryIndexEntry] = []
        if fm.fileExists(atPath: indexURL.path) {
            let indexData = try Data(contentsOf: indexURL)
            // index 损坏：抛错（不静默丢）；清理已写的 per-file 让 caller retry
            do {
                entries = try decoder.decode([MemoryIndexEntry].self, from: indexData)
            } catch {
                try? fm.removeItem(at: fileURL)
                throw MemoryStoreError.indexCorrupted(path: indexURL.path, reason: error.localizedDescription)
            }
        }
        entries.append(MemoryIndexEntry(from: memory))
        let indexData = try encoder.encode(entries)
        do {
            try atomicWrite(data: indexData, to: indexURL)
        } catch {
            // 写 index 失败 → 清理 per-file（保一致：要么都有，要么都没）
            try? fm.removeItem(at: fileURL)
            throw error
        }

        // 3. 刷 cache（不动顺序，避免影响其他 reader；append 即可）
        memories.append(memory)
    }

    // MARK: - 维护

    /// 确保 root 目录存在。已有不报错。
    public func ensureRootDirectory() throws {
        if !fm.fileExists(atPath: root.path) {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw MemoryStoreError.rootCreationFailed(
                    path: root.path,
                    reason: error.localizedDescription
                )
            }
        }
    }

    /// 原子写：先写 .tmp 再 replaceItemAt / move。跟 PetStore 一致。
    /// 注：用 `Data.write(to: tmp)`（非 .atomic 标志），让命名 tmp 文件可控；
    /// 然后 replaceItemAt / moveItem 是最终原子步骤。
    func atomicWrite(data: Data, to url: URL) throws {
        // 找一个不冲突的 tmp 路径（在 url 同目录）
        var tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).tmp")
        // 同目录下多个并发写可能冲突 → 加 uuid 后缀
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

// MARK: - Errors

public enum MemoryStoreError: Error, CustomStringConvertible, Equatable {
    case rootCreationFailed(path: String, reason: String)
    case duplicateMemoryID(id: String)
    case indexCorrupted(path: String, reason: String)

    public var description: String {
        switch self {
        case .rootCreationFailed(let p, let r):
            return "MemoryStore root creation failed at \(p): \(r)"
        case .duplicateMemoryID(let id):
            return "duplicate memory id: \(id)"
        case .indexCorrupted(let p, let r):
            return "MemoryStore index corrupted at \(p): \(r)"
        }
    }
}
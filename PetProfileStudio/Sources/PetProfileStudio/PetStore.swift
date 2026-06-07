// PetStore.swift
// PetStore — pet 目录持久化 + CRUD + 列表加载 + .omppet 导出
//
// 设计决策：
//   - 单例 + 可注入 root：默认 root = ~/Library/Application Support/oh-my-pet/pets/，
//     测试可以注入临时目录 URL，避免污染真 ~/Library。
//   - 物理布局：每个 pet 一个子目录，含 manifest.json + assets/（v1 schema）。
//   - 持久化字段跟 PetProfileKit.ProfileIO 对齐（prettyPrinted + sortedKeys + ISO8601）。
//   - 原子写：先写 .tmp 再 rename / replaceItemAt。
//   - "create" = 复制整个 LoadedPetProfile.profileRoot（含 manifest + assets）到目标 pet 目录。
//     "update" = 重新写 manifest.json（assets 保持不动）。"delete" = 删子目录。
//   - "export" = 用 /usr/bin/zip 把整个 pet 目录打成 .omppet（zip 格式）— 不引入第三方 zip 库。
//   - PetSummary 是 derived：从 manifest 读 id / name / species / createdAt，不单独存 metadata 索引。
//     （schema 草案约定 manifest 是 source of truth）
//
// 边界 / 不做：
//   - 不实现 daily ritual / shared memory 写盘（属 P2-F）；本包只读 memories.json / stickers.json /
//     generation-history.json（如果存在）。"today companion record" 走 todayMemories() 过滤。
//   - 不接真 LLM；创建 pet 用 fixture mock。
//   - 不改 PetProfileKit / PetProfileRuntime / PetProfileOnboarding 既有。
//

import Foundation
import PetProfile
import PetProfileRuntime

// MARK: - PetSummary

/// Pet 列表屏用的摘要 — derived from manifest，不单独存盘
public struct PetSummary: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    /// 物种 / 性格标签（来自 PersonaCard.backstoryTags.first 兜底 "custom"）
    public let species: String
    /// 创建时间（来自 manifest.createdAt；缺省值 = 1970-01-01T00:00:00Z，避免可选）
    public let createdAt: Date

    public init(id: String, name: String, species: String, createdAt: Date) {
        self.id = id
        self.name = name
        self.species = species
        self.createdAt = createdAt
    }
}

// MARK: - PetStore

public final class PetStore {
    /// 默认单例 — root = ~/Library/Application Support/oh-my-pet/pets/
    public static let shared: PetStore = PetStore(root: PetStore.defaultRoot())

    /// pet 目录根；可注入（测试用）
    public let root: URL

    /// 当前内存里 cache 的列表（懒加载 — loadAll() 后填）
    public private(set) var pets: [PetSummary] = []

    public init(root: URL) {
        self.root = root
    }

    // MARK: - 默认 root

    public static func defaultRoot() -> URL {
        // 注：app support 目录创建可能失败；这里跟 OnboardingStateStore 一致地
        // 用 FileManager 拼路径 + 失败时 fallback 到 tmp。
        if let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            return appSupport
                .appendingPathComponent("oh-my-pet", isDirectory: true)
                .appendingPathComponent("pets", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("oh-my-pet-fallback", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
    }

    /// 给定 pet id 的子目录 URL
    public func petDirectory(for id: String) -> URL {
        root.appendingPathComponent(id, isDirectory: true)
    }

    /// 给定 pet id 的 manifest URL
    public func manifestURL(for id: String) -> URL {
        petDirectory(for: id).appendingPathComponent("manifest.json")
    }

    // MARK: - 加载

    /// 扫描 root 下所有 pet 子目录，解析 manifest，返回 [PetSummary]（按 name 排序）
    /// - Throws: I/O / 解析错误
    public func loadAll() throws -> [PetSummary] {
        // 确保 root 存在
        try ensureRootDirectory()

        let fm = FileManager.default
        let entries = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var summaries: [PetSummary] = []
        for entry in entries {
            let manifest = entry.appendingPathComponent("manifest.json")
            guard fm.fileExists(atPath: manifest.path) else {
                continue
            }
            do {
                let p = try ProfileIO.decodeV1(from: manifest)
                summaries.append(makeSummary(from: p))
            } catch {
                // 单个 pet 解析失败 → skip，不要让整个 loadAll 崩
                FileHandle.standardError.write(Data(
                    "PetStore: skip \(entry.lastPathComponent) — manifest decode failed: \(error)\n".utf8
                ))
                continue
            }
        }

        // 按 name 排序（升序，A-Z；中文按 Unicode 顺序）
        summaries.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        pets = summaries
        return summaries
    }

    /// 加载单个 pet — 返回 LoadedPetProfile（runtime-friendly，manifest + 解析后的 asset URLs）
    /// - Throws: I/O / 解析 / 校验错误
    public func load(id: String) throws -> LoadedPetProfile {
        let manifest = manifestURL(for: id)
        let loader = PetProfileLoader()
        return try loader.loadProfile(from: manifest)
    }

    // MARK: - CRUD

    /// 把 LoadedPetProfile 的整目录（manifest + assets）复制到 root/<id>/
    /// - Throws: 已存在（id 冲突）/ 复制失败
    /// 注：
    ///   - dest 的 manifest.json **总是**用 profile.manifest（即 in-memory 状态）写盘。
    ///     这样编辑 / draft 改的名字 / tags 会被保留。
    ///   - assets/ 等非 manifest 文件从 profile.profileRoot 复制过来（共享 assets/ 目录）。
    public func create(profile: LoadedPetProfile) throws {
        let id = profile.manifest.id.raw
        let dest = petDirectory(for: id)
        let destManifest = manifestURL(for: id)

        let fm = FileManager.default
        if fm.fileExists(atPath: destManifest.path) {
            throw PetStoreError.alreadyExists(id: id)
        }

        // 确保 root 存在
        try ensureRootDirectory()

        // 创建目标 pet 目录
        do {
            try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            throw PetStoreError.copyFailed(
                from: profile.profileRoot.path,
                to: dest.path,
                reason: "create dest dir: \(error.localizedDescription)"
            )
        }

        do {
            // 1. 复制 assets/ 等非 manifest 子目录
            let entries = try fm.contentsOfDirectory(
                at: profile.profileRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasSuffix(".json") {
                    continue  // manifest 自己写，不从源 copy
                }
                if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    let dstSubdir = dest.appendingPathComponent(name, isDirectory: true)
                    if fm.fileExists(atPath: dstSubdir.path) {
                        try? fm.removeItem(at: dstSubdir)
                    }
                    try fm.copyItem(at: entry, to: dstSubdir)
                }
            }

            // 2. 写 manifest.json（用 in-memory profile.manifest，保留 draft 编辑）
            let data = try ProfileIO.encodeV1(profile.manifest)
            try atomicWrite(data: data, to: destManifest)
        } catch {
            // 清理半成品
            try? fm.removeItem(at: dest)
            throw PetStoreError.copyFailed(
                from: profile.profileRoot.path,
                to: dest.path,
                reason: "asset/manifest copy: \(error.localizedDescription)"
            )
        }

        // 重新解析一次，refresh 内存 cache
        _ = try loadAll()
    }

    /// 更新 pet — 重新写 manifest.json 到 pet 目录
    /// （assets 路径保持不动；schema 保证 manifest 跟 assets 一致）
    /// - Throws: pet 不存在 / 写盘失败 / manifest 校验失败
    public func update(_ profile: LoadedPetProfile) throws {
        let id = profile.manifest.id.raw
        let manifest = manifestURL(for: id)

        let fm = FileManager.default
        guard fm.fileExists(atPath: manifest.path) else {
            throw PetStoreError.notFound(id: id)
        }

        // 写 v1 manifest（prettyPrinted + sortedKeys，跟 ProfileIO 对齐）
        let data = try ProfileIO.encodeV1(profile.manifest)
        try atomicWrite(data: data, to: manifest)

        // refresh 内存 cache
        _ = try loadAll()
    }

    /// 删除 pet 目录（不可逆）
    public func delete(id: String) throws {
        let dir = petDirectory(for: id)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            throw PetStoreError.notFound(id: id)
        }
        do {
            try fm.removeItem(at: dir)
        } catch {
            throw PetStoreError.deleteFailed(id: id, reason: error.localizedDescription)
        }
        // refresh 内存 cache
        _ = try loadAll()
    }

    // MARK: - Export

    /// 把整个 pet 目录打包成 .omppet（zip 格式），输出到目标 URL
    /// - 用 /usr/bin/zip（macOS 自带）— 不引入第三方 zip 库
    /// - zip 内保留目录结构（相对 pet 目录）
    /// - Throws: 导出失败 / pet 不存在 / /usr/bin/zip 不存在
    public func export(profileID: String, to outputURL: URL) throws {
        let dir = petDirectory(for: profileID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else {
            throw PetStoreError.notFound(id: profileID)
        }

        // 确保输出 URL 父目录存在
        let parent = outputURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw PetStoreError.exportFailed(
                    reason: "create parent dir failed: \(error.localizedDescription)"
                )
            }
        }

        // 删掉已存在文件，避免 zip 累加
        if fm.fileExists(atPath: outputURL.path) {
            try? fm.removeItem(at: outputURL)
        }

        // /usr/bin/zip -r <output> <dir-name>
        //   -r: recursive
        //   cd 到 parent 后把 dir-name 整体打进去，zip 内根 = <dir-name>/
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-X", outputURL.path, dir.lastPathComponent]

        // 让 zip 读 dir 的绝对路径
        process.currentDirectoryURL = dir.deletingLastPathComponent()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw PetStoreError.zipNotAvailable(reason: error.localizedDescription)
        }
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "<no stderr>"
            throw PetStoreError.exportFailed(reason: "zip exit \(process.terminationStatus): \(errStr)")
        }
    }

    // MARK: - Pet House 数据（read-only）

    /// memories.json（共享记忆）— P2-F 写、本包读
    public func loadMemories(petID: String) throws -> [PetMemory] {
        let url = petDirectory(for: petID).appendingPathComponent("memories.json")
        return try PetHouseDataStore.readJSON([PetMemory].self, from: url) ?? []
    }

    /// stickers.json（贴纸 + 房间物件）
    public func loadStickers(petID: String) throws -> [PetSticker] {
        let url = petDirectory(for: petID).appendingPathComponent("stickers.json")
        return try PetHouseDataStore.readJSON([PetSticker].self, from: url) ?? []
    }

    /// generation-history.json（生成记录时间线）
    public func loadGenerationHistory(petID: String) throws -> [GenerationHistoryEntry] {
        let url = petDirectory(for: petID).appendingPathComponent("generation-history.json")
        return try PetHouseDataStore.readJSON([GenerationHistoryEntry].self, from: url) ?? []
    }

    /// "今天" 的 companion record（从 memories 过滤 createdAt == 今天）
    public func todayMemories(petID: String, calendar: Calendar = .current, now: Date = Date()) throws -> [PetMemory] {
        let all = try loadMemories(petID: petID)
        return all.filter { calendar.isDate($0.createdAt, inSameDayAs: now) }
    }

    // MARK: - 写盘辅助

    func ensureRootDirectory() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: true)
            } catch {
                throw PetStoreError.rootCreationFailed(path: root.path, reason: error.localizedDescription)
            }
        }
    }

    func atomicWrite(data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            // 清理可能残留的 tmp
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    // MARK: - Summary 派生

    func makeSummary(from p: PetProfileV1) -> PetSummary {
        let species = p.persona.backstoryTags?.first ?? "custom"
        let createdAt = p.createdAt ?? Date(timeIntervalSince1970: 0)
        return PetSummary(
            id: p.id.raw,
            name: p.name,
            species: species,
            createdAt: createdAt
        )
    }
}

// MARK: - Errors

public enum PetStoreError: Error, CustomStringConvertible, Equatable {
    case rootCreationFailed(path: String, reason: String)
    case alreadyExists(id: String)
    case notFound(id: String)
    case copyFailed(from: String, to: String, reason: String)
    case deleteFailed(id: String, reason: String)
    case exportFailed(reason: String)
    case zipNotAvailable(reason: String)
    case jsonReadFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .rootCreationFailed(let p, let r):
            return "PetStore root creation failed at \(p): \(r)"
        case .alreadyExists(let id):
            return "pet already exists: \(id)"
        case .notFound(let id):
            return "pet not found: \(id)"
        case .copyFailed(let f, let t, let r):
            return "copy failed from \(f) to \(t): \(r)"
        case .deleteFailed(let id, let r):
            return "delete failed for \(id): \(r)"
        case .exportFailed(let r):
            return "export failed: \(r)"
        case .zipNotAvailable(let r):
            return "/usr/bin/zip not available: \(r)"
        case .jsonReadFailed(let p, let r):
            return "JSON read failed at \(p): \(r)"
        }
    }
}

// MARK: - Pet House 数据模型

/// Shared memory（focus / task 完成的记忆）
public struct PetMemory: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: Kind
    public let title: String
    public let detail: String?
    public let createdAt: Date
    public let expressionAtTime: String?

    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case focusComplete
        case taskComplete
        case firstMeet
        case shared
    }

    public init(
        id: String,
        kind: Kind,
        title: String,
        detail: String? = nil,
        createdAt: Date,
        expressionAtTime: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
        self.expressionAtTime = expressionAtTime
    }
}

/// 贴纸 / 房间物件
public struct PetSticker: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: Kind
    public let assetPath: String?
    public let positionHint: String?
    public let acquiredAt: Date

    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case sticker
        case roomObject
    }

    public init(
        id: String,
        name: String,
        kind: Kind,
        assetPath: String? = nil,
        positionHint: String? = nil,
        acquiredAt: Date
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.assetPath = assetPath
        self.positionHint = positionHint
        self.acquiredAt = acquiredAt
    }
}

/// 生成记录
public struct GenerationHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let kind: Kind
    public let summary: String
    public let createdAt: Date

    public enum Kind: String, Codable, Equatable, Sendable, CaseIterable {
        case visual
        case state
        case voiceStyle
        case voiceClone
    }

    public init(
        id: String,
        kind: Kind,
        summary: String,
        createdAt: Date
    ) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.createdAt = createdAt
    }
}

// MARK: - Pet House 数据 store helper

enum PetHouseDataStore {
    /// 读 JSON — 文件不存在 → 返回 nil（不抛错）；损坏 → 抛 .jsonReadFailed
    static func readJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(type, from: data)
        } catch {
            throw PetStoreError.jsonReadFailed(path: url.path, reason: error.localizedDescription)
        }
    }
}

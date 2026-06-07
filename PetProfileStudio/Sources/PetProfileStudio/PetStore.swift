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

        // 计算 manifest 引用的 asset 相对路径集合（用于过滤 assets/）
        let referenced = manifestReferencedAssets(in: profile.manifest)

        do {
            // 1. 遍历 source profileRoot，按子目录分类处理
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
                guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    continue  // 非目录（隐藏文件等）跳过
                }
                let dstSubdir = dest.appendingPathComponent(name, isDirectory: true)
                if fm.fileExists(atPath: dstSubdir.path) {
                    try? fm.removeItem(at: dstSubdir)
                }
                // 2. assets/ 子目录：只复制 manifest 引用的文件
                //    其他子目录（persona / house 等）：整目录复制（house 不在 v1 manifest，
                //    但 source 可能有；pet-product/pet-asset 后续扩字段时再用）
                if name == "assets" {
                    try copyAssetsFiltered(
                        from: entry,
                        to: dstSubdir,
                        referenced: referenced,
                        fm: fm
                    )
                } else {
                    try fm.copyItem(at: entry, to: dstSubdir)
                }
            }

            // 3. 写 manifest.json（用 in-memory profile.manifest，保留 draft 编辑）
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

    // MARK: - Visual asset 更新（P2-E2 扩展）

    /// 更新某个 pet 的某个 state 视觉资产。
    /// 行为：
    ///   - 写入 `{petRoot}/assets/visual/states/{state}.png`
    ///   - **不动** manifest 顶层（spec §2.5 不变量：House 写盘只动 assets/）
    ///   - 不需要 manifest 引用更新（visual.states.{state} 已经是该路径，写文件本身
    ///     就是覆盖 — 下次 load 看到的就是新文件）
    /// - Throws: pet 不存在 / 写盘失败
    public func updateVisual(petID: String, state: VisualState, sourceURL: URL) throws {
        let petDir = petDirectory(for: petID)
        let fm = FileManager.default
        guard fm.fileExists(atPath: petDir.path) else {
            throw PetStoreError.notFound(id: petID)
        }
        // source 文件存在性由调用方（UploadImageProvider）保证；
        // 这里只关心落盘。
        let statesDir = petDir
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("visual", isDirectory: true)
            .appendingPathComponent("states", isDirectory: true)
        do {
            try fm.createDirectory(at: statesDir, withIntermediateDirectories: true)
        } catch {
            throw PetStoreError.copyFailed(
                from: sourceURL.path,
                to: statesDir.path,
                reason: "create states dir: \(error.localizedDescription)"
            )
        }
        let dstURL = statesDir.appendingPathComponent("\(state.rawValue).png")
        do {
            if fm.fileExists(atPath: dstURL.path) {
                try? fm.removeItem(at: dstURL)
            }
            try fm.copyItem(at: sourceURL, to: dstURL)
        } catch {
            throw PetStoreError.copyFailed(
                from: sourceURL.path,
                to: dstURL.path,
                reason: "copy state visual: \(error.localizedDescription)"
            )
        }
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

    /// 把 pet 目录打包成 .omppet（zip 格式），输出到目标 URL。
    ///
    /// **Awareness flag 修复（P2-H）**：原版用 `zip -r <dir>` 把整个 pet 目录打进去，
    /// 包含未引用的 assets（其它 pet 的资产可能共享 source dir 时被一起带进来）。
    /// 本方法改为显式 file list：只 zip manifest.json + 已知顶层数据文件 +
    /// manifest 引用的 assets。
    ///
    /// - 用 /usr/bin/zip（macOS 自带）— 不引入第三方 zip 库
    /// - zip 内保留目录结构（相对 pet 目录；-r 让 asset 子目录结构保留）
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

        // 1. 读 manifest 拿到 asset 引用集合
        let manifestPath = manifestURL(for: profileID)
        let manifest = try ProfileIO.decodeV1(from: manifestPath)
        let referenced = manifestReferencedAssets(in: manifest)

        // 2. 构造要打入 zip 的相对路径列表
        var itemsToZip: [String] = ["manifest.json"]

        // 顶层数据文件（如有就加）—— 这些是 Pet House 的辅助 JSON
        for topName in ["memories.json", "stickers.json", "generation-history.json", "persona.json"] {
            if fm.fileExists(atPath: dir.appendingPathComponent(topName).path) {
                itemsToZip.append(topName)
            }
        }

        // house/ 子目录（如有就整个打）—— v1 manifest 不含 house 字段，
        // 但 P2-F 之后 house/ 可能由 runtime 写入；保留以兼容
        let houseDir = dir.appendingPathComponent("house", isDirectory: true)
        if fm.fileExists(atPath: houseDir.path) {
            // 全部进 zip —— house/ 内容由 Pet House 模块管理，资产过滤不是本 plan 范围
            if let entries = try? fm.subpathsOfDirectory(atPath: houseDir.path) {
                for rel in entries {
                    itemsToZip.append("house/\(rel)")
                }
            }
        }

        // 3. manifest 引用的 assets（按相对路径去重加入）
        for assetRel in referenced {
            // 验证 source 真有这个文件（manifest 引用的路径可能在 source 里缺失；
            // 这种情况下 zip 仍然会把路径写进去但文件是 broken —— 跟旧版行为一致）
            let absURL = URL(fileURLWithPath: assetRel, relativeTo: dir).standardizedFileURL
            if fm.fileExists(atPath: absURL.path) {
                itemsToZip.append(assetRel)
            }
        }

        // 4. zip -r <output> <items...>（items 全部相对 dir 的相对路径）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-r", "-X", outputURL.path] + itemsToZip
        process.currentDirectoryURL = dir

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

    /// 计算 manifest 引用的所有 asset 相对路径集合（用于过滤 assets/ 目录）。
    /// **Awareness flag 修复（P2-H）**：防止 export / create 把未引用的 assets 带进
    /// 当前 pet 的存储 / .omppet 包。
    ///
    /// 覆盖的引用源（v1 schema）：
    ///   - `visual.states.{idle,focus,happy,tired,celebrate}`（5 个 string 路径）
    ///   - `expression.states.{idle,focus,happy,tired,celebrate}.asset_path`（5 个）
    ///   - `expression.extended_emotions[].asset_path`（N 个）
    ///   - `action.idle.asset_path`（optional）
    ///   - `action.reactions[].asset_path`（optional 数组）
    ///   - `audio.voice_clone_consent.sample_path`（optional）
    ///
    /// 返回值已 normalize：去掉前导 `./` 和 `/`，统一用 `/` 分隔。
    func manifestReferencedAssets(in manifest: PetProfileV1) -> Set<String> {
        var paths = Set<String>()

        // 1. visual.states（5 个 string）
        let vs = manifest.visual.states
        for p in [vs.idle, vs.focus, vs.happy, vs.tired, vs.celebrate] {
            let n = normalizeAssetPath(p)
            if !n.isEmpty {
                paths.insert(n)
            }
        }

        // 2. expression.states（5 个 ExpressionFace.assetPath）
        let es = manifest.expression.states
        for face in [es.idle, es.focus, es.happy, es.tired, es.celebrate] {
            paths.insert(normalizeAssetPath(face.assetPath))
        }

        // 3. expression.extended_emotions（变长）
        for ext in (manifest.expression.extendedEmotions ?? []) {
            paths.insert(normalizeAssetPath(ext.assetPath))
        }

        // 4. action.idle（optional）
        if let p = manifest.action.idle.assetPath {
            paths.insert(normalizeAssetPath(p))
        }

        // 5. action.reactions（optional 数组）
        for r in manifest.action.reactions {
            if let p = r.assetPath {
                paths.insert(normalizeAssetPath(p))
            }
        }

        // 6. voice clone sample（optional）
        if let p = manifest.audio.voiceCloneConsent?.samplePath {
            paths.insert(normalizeAssetPath(p))
        }

        return paths
    }

    /// 规范化 asset 相对路径：去掉前导 `./` 和 `/`，保留 `/` 分隔。
    /// 防御性 —— validator 已经把 `..` / 绝对路径拒了，但这里再保险一层。
    private func normalizeAssetPath(_ path: String) -> String {
        var p = path
        while p.hasPrefix("./") {
            p.removeFirst(2)
        }
        while p.hasPrefix("/") {
            p.removeFirst()
        }
        return p
    }

    /// 把 source assets/ 子目录**只**复制 manifest 引用的文件到 dest。
    /// 未引用的文件**不**复制（节省空间 + 避免 bloat）。
    /// - `referenced`：manifest 引用的相对路径集合（已 normalize）
    /// - 递归遍历 source；命中路径的文件 → copy；未命中的 → skip
    /// - 必要时创建中间子目录
    func copyAssetsFiltered(
        from source: URL,
        to dest: URL,
        referenced: Set<String>,
        fm: FileManager
    ) throws {
        // 把 referenced 全部归到 dest/ 前缀下；source/ 不在 referenced 集合里
        // （manifest 引用的都是 "assets/visual/..." 形式，source/ 本身不带 "assets/"）
        let sourcePath = source.standardizedFileURL.path

        // 把所有 "assets/xxx" → "xxx" 形式（因为递归遍历时 file 在 source 内部）
        // 实际上 referenced 已是 "assets/visual/..." 形式，遍历时拼相对 source 的路径
        func relPathFromSource(of fileURL: URL) -> String {
            let p = fileURL.standardizedFileURL.path
            let prefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
            if p.hasPrefix(prefix) {
                return String(p.dropFirst(prefix.count))
            }
            return p
        }

        func isReferenced(_ fileURL: URL) -> Bool {
            // 形如 assets/visual/states/idle.png
            let relFromSource = relPathFromSource(of: fileURL)
            return referenced.contains("assets/\(relFromSource)")
        }

        func walk(_ dir: URL) throws {
            let entries = try fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for entry in entries {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if isDir {
                    try walk(entry)
                } else {
                    guard isReferenced(entry) else { continue }
                    let relFromDest = relPathFromSource(of: entry)
                    let dstFile = URL(fileURLWithPath: relFromDest, relativeTo: dest).standardizedFileURL
                    let dstParent = dstFile.deletingLastPathComponent()
                    if !fm.fileExists(atPath: dstParent.path) {
                        try fm.createDirectory(at: dstParent, withIntermediateDirectories: true)
                    }
                    if fm.fileExists(atPath: dstFile.path) {
                        try? fm.removeItem(at: dstFile)
                    }
                    try fm.copyItem(at: entry, to: dstFile)
                }
            }
        }

        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try walk(source)
    }

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

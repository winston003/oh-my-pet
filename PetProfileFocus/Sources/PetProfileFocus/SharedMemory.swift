// SharedMemory.swift
// SharedMemory 数据模型 + MemoryType
//
// 责任：
//   - 定义 P2-F "shared memory" 数据结构（focus + task 完成 → 写入一条 memory）
//   - 持久化交给 MemoryStore；本文件只定义模型 + 工厂 + computed
//
// 设计决策：
//   - petID = LoadedPetProfile.manifest.id.raw（String，跟 PetStore.PetMemory 一致）
//   - type 限定 2 类：focus / task（firstMeet / shared 留给 PetStore 自管，不混进来）
//   - title 是 pet 视角对用户的描述（"Pako 陪你专注了 25 分钟" / "Pako 看你完成 <task>"）
//   - durationSeconds：focus 有；task 是 nil
//   - metadata：可扩展 dict，focus → { "task_name": "..." }；task → { "task_id": "<uuid>" }
//   - 兼容 PetStore.PetMemory：本包的 SharedMemory **不**复用 PetStore.PetMemory 的类型
//     （PetStore 是 frozen，PetMemory.Kind 是 focusComplete/taskComplete；本包用 focus/task）。
//     未来 P2-G 可写 converter 把 SharedMemory → PetMemory 灌进 pet 目录的 memories.json。
//
// 不做：
//   - 不读 / 不写 PetStore.PetMemory（PetStore 是 frozen，本包不导入它的具体读写 API
//     之外的可变字段；只 import 类型 + PetStore 类型本身 + PetStore.shared / loadAll）
//   - 不写 asset / 不调 audio
//   - 不接真 LLM 写 memory 描述（title 用 deterministic 模板）
//
import Foundation

// MARK: - SharedMemory

/// P2-F 共享记忆数据模型 — focus + task 完成各产生一条
public struct SharedMemory: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    /// 关联 pet id（来自 LoadedPetProfile.manifest.id.raw）
    public let petID: String
    public let type: MemoryType
    /// pet 视角的简短描述（"Pako 陪你专注了 25 分钟" / "Pako 看你完成了「写设计稿」"）
    public let title: String
    public let createdAt: Date
    /// focus 时长（秒）；task 类型为 nil
    public let durationSeconds: Int?
    /// 可扩展 metadata：focus → { "task_name": "..." }；task → { "task_id": "<uuid>" }
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        petID: String,
        type: MemoryType,
        title: String,
        createdAt: Date = Date(),
        durationSeconds: Int? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.petID = petID
        self.type = type
        self.title = title
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.metadata = metadata
    }
}

public enum MemoryType: String, Codable, Equatable, Sendable, CaseIterable {
    case focus
    case task
}

// MARK: - Memory factory helpers

public enum SharedMemoryFactory {
    /// focus 完成 → 生成一条 focus memory。
    /// - Parameters:
    ///   - petName: pet 展示名（用于 title）
    ///   - petID: pet id（写进 metadata 之外也写 petID 字段）
    ///   - durationSeconds: 本次 focus 时长（秒）
    ///   - taskName: 可选；focus 时附带的 task 名（放进 metadata）
    ///   - createdAt: 默认 now；测试可注入
    public static func focusMemory(
        petName: String,
        petID: String,
        durationSeconds: Int,
        taskName: String? = nil,
        createdAt: Date = Date()
    ) -> SharedMemory {
        let mins = max(1, durationSeconds / 60)
        let title = "\(petName) 陪你专注了 \(mins) 分钟"
        var meta: [String: String] = [:]
        if let taskName = taskName, !taskName.isEmpty {
            meta["task_name"] = taskName
        }
        return SharedMemory(
            petID: petID,
            type: .focus,
            title: title,
            createdAt: createdAt,
            durationSeconds: durationSeconds,
            metadata: meta
        )
    }

    /// task 完成 → 生成一条 task memory。
    public static func taskMemory(
        petName: String,
        petID: String,
        taskName: String,
        taskID: UUID,
        createdAt: Date = Date()
    ) -> SharedMemory {
        let title = "\(petName) 看你完成了「\(taskName)」"
        let meta: [String: String] = [
            "task_id": taskID.uuidString,
            "task_name": taskName
        ]
        return SharedMemory(
            petID: petID,
            type: .task,
            title: title,
            createdAt: createdAt,
            durationSeconds: nil,
            metadata: meta
        )
    }
}
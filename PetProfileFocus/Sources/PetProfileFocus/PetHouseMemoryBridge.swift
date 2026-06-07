// PetHouseMemoryBridge.swift
// PetProfileStudio 集成：把 SharedMemory 转成 PetStore.PetMemory（read-only）
//
// 责任：
//   - 提供 SharedMemory → PetMemory 的转换函数
//   - 提供"通过 MemoryStore 拿某 pet 全部 PetMemory"的 helper（给未来 P2-G Pet House Tab 用）
//   - 不写 PetStore（PetStore.PetHouseDataStore.readJSON 是 frozen；本包不 import 它做写入）
//
// 设计决策：
//   - PetStore 是 frozen；PetMemory.Kind 跟我们不一样：
//       SharedMemory.type == .focus  →  PetMemory.Kind == .focusComplete
//       SharedMemory.type == .task   →  PetMemory.Kind == .taskComplete
//   - PetMemory.expressionAtTime：默认 nil（不在 memory 层感知 visual state）
//   - PetMemory.id：String；SharedMemory.id：UUID；UUID.uuidString 直接转
//   - detail 字段：SharedMemory.title（已经是描述）
//
// 集成路径：
//   - 本包只写 MemoryStore（~/.../oh-my-pet/memories/）
//   - 未来 P2-G 的 Pet House Tab 可以：
//       1. 直接调 MemoryStore.shared.load(forPetID:) → [SharedMemory] → 转 [PetMemory]
//       2. 或者写 PetStore（写入 pet 目录的 memories.json）让 PetStore 旧 read API 工作
//     当前实现选 (1)。
//
// 不做：
//   - 不写 PetStore.PetMemory 到 pet 目录（PetStore 是 frozen，PetMemory 写入端不在本包）
//   - 不接真 LLM 重新生成 memory title
//   - 不做 memory editing / 删除
//
import Foundation
import PetProfileStudio

public enum PetHouseMemoryBridge {

    /// SharedMemory → PetMemory（给 Pet House Tab UI 用）
    public static func toPetMemory(_ m: SharedMemory) -> PetMemory {
        return PetMemory(
            id: m.id.uuidString,
            kind: kindFor(m.type),
            title: m.title,
            detail: detailFor(m),
            createdAt: m.createdAt,
            expressionAtTime: nil
        )
    }

    /// 给定 petID，取全部 SharedMemory → 转成 PetMemory 列表，按 createdAt 升序。
    /// 供未来 P2-G Pet House Tab 直接消费。
    public static func petMemories(petID: String, store: MemoryStore = .shared) throws -> [PetMemory] {
        let memories = try store.load(forPetID: petID)
        return memories.map(toPetMemory)
    }

    // MARK: - 私有

    private static func kindFor(_ type: MemoryType) -> PetMemory.Kind {
        switch type {
        case .focus: return .focusComplete
        case .task: return .taskComplete
        }
    }

    private static func detailFor(_ m: SharedMemory) -> String? {
        switch m.type {
        case .focus:
            if let taskName = m.metadata["task_name"] {
                return "Focus \(m.durationSeconds ?? 0) seconds · task: \(taskName)"
            }
            return "Focus \(m.durationSeconds ?? 0) seconds"
        case .task:
            return m.metadata["task_name"]
        }
    }
}
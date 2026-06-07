// PetProfileV1.swift
// PetProfile v1 顶层 manifest + 5 pack + persona card
// Schema: .private/product-design/mvp-pet-schema-draft.md
//
// 设计要点：
//   - 顶层 6 个 required 字段：version, id, name, visual, audio, action, expression, humor, persona
//     （注：schema 草案里 required 写了 6 个 key，version+id+name+5 packs = 8 项；写齐）
//   - 所有 asset 路径保持相对 profile root，运行时再 resolve
//   - 用 enum 表达字符串 enum 字段（render_mode / humor_style / trigger 等），避免拼写错误
//   - 字符串 ID 模式：^pet_[a-z0-9_]{6,32}$
//

import Foundation

// MARK: - Top-level manifest

public struct PetProfileV1: Codable, Equatable, Sendable {
    public let version: VersionString
    public let minRuntimeVersion: String?
    public let id: ProfileID
    public let name: String
    public let createdAt: Date?
    public let locale: String?
    public let visual: VisualPack
    public let audio: AudioPack
    public let action: ActionPack
    public let expression: ExpressionPack
    public let humor: HumorPack
    public let persona: PersonaCard

    enum CodingKeys: String, CodingKey {
        case version
        case minRuntimeVersion = "min_runtime_version"
        case id
        case name
        case createdAt = "created_at"
        case locale
        case visual, audio, action, expression, humor, persona
    }

    public init(
        version: VersionString = .v1_0_0,
        minRuntimeVersion: String? = nil,
        id: ProfileID,
        name: String,
        createdAt: Date? = nil,
        locale: String? = nil,
        visual: VisualPack,
        audio: AudioPack,
        action: ActionPack,
        expression: ExpressionPack,
        humor: HumorPack,
        persona: PersonaCard
    ) {
        self.version = version
        self.minRuntimeVersion = minRuntimeVersion
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.locale = locale
        self.visual = visual
        self.audio = audio
        self.action = action
        self.expression = expression
        self.humor = humor
        self.persona = persona
    }
}

// MARK: - Version

public enum VersionString: String, Codable, Equatable, Sendable, CaseIterable {
    case v0_1_0 = "0.1.0"
    case v1_0_0 = "1.0.0"

    public var isV1: Bool { self == .v1_0_0 }
}

// MARK: - Profile ID

public struct ProfileID: Codable, Equatable, Sendable, Hashable, CustomStringConvertible {
    public let raw: String
    public init(raw: String) { self.raw = raw }
    public var description: String { raw }

    /// Schema pattern: ^pet_[a-z0-9_]{6,32}$
    public static let pattern: String = "^pet_[a-z0-9_]{6,32}$"
    public func matchesPattern() -> Bool {
        raw.range(of: Self.pattern, options: .regularExpression) != nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

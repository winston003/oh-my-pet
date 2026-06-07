// PersonaCard.swift
// 故事通道 — 一句话设定 + 关系定位 + 反复出现的小细节
// Schema 草案第 8 节
//

import Foundation

public struct PersonaCard: Codable, Equatable, Sendable {
    public let name: String
    public let loreShort: String
    public let loreFull: String?
    public let relationshipWithUser: String?
    public let recurringMotifs: [String]?
    public let backstoryTags: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case loreShort = "lore_short"
        case loreFull = "lore_full"
        case relationshipWithUser = "relationship_with_user"
        case recurringMotifs = "recurring_motifs"
        case backstoryTags = "backstory_tags"
    }

    public init(
        name: String,
        loreShort: String,
        loreFull: String? = nil,
        relationshipWithUser: String? = nil,
        recurringMotifs: [String]? = nil,
        backstoryTags: [String]? = nil
    ) {
        self.name = name
        self.loreShort = loreShort
        self.loreFull = loreFull
        self.relationshipWithUser = relationshipWithUser
        self.recurringMotifs = recurringMotifs
        self.backstoryTags = backstoryTags
    }
}

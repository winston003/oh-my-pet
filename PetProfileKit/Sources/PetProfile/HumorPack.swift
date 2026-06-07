// HumorPack.swift
// 幽默通道 — humor_style + persona_system_prompt + joke_density + meme_pool + self_deprecation_topics
// Schema 草案第 7 节
//

import Foundation

public struct HumorPack: Codable, Equatable, Sendable {
    public let humorStyle: HumorStyle
    public let personaSystemPrompt: String
    public let jokeDensity: Double
    public let memePool: [String]?
    public let selfDeprecationTopics: [String]?

    enum CodingKeys: String, CodingKey {
        case humorStyle = "humor_style"
        case personaSystemPrompt = "persona_system_prompt"
        case jokeDensity = "joke_density"
        case memePool = "meme_pool"
        case selfDeprecationTopics = "self_deprecation_topics"
    }

    public init(
        humorStyle: HumorStyle,
        personaSystemPrompt: String,
        jokeDensity: Double = 0.3,
        memePool: [String]? = nil,
        selfDeprecationTopics: [String]? = nil
    ) {
        self.humorStyle = humorStyle
        self.personaSystemPrompt = personaSystemPrompt
        self.jokeDensity = jokeDensity
        self.memePool = memePool
        self.selfDeprecationTopics = selfDeprecationTopics
    }
}

public enum HumorStyle: String, Codable, Equatable, Sendable, CaseIterable {
    case deadpan
    case selfDeprecating = "self-deprecating"
    case sarcastic
    case gentle
    case playful
    case cute
    case cold
    case metaIronic = "meta-ironic"
}

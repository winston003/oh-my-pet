// PetProfileV01.swift
// PetProfile v0.1.0 旧 model — 来自 mvp-design.md 194-256 行
// 只用于读和升级。新代码应该构造 v1。
//

import Foundation

public struct PetProfileV01: Codable, Equatable, Sendable {
    public let version: String
    public let id: String
    public let name: String
    public let identity: Identity?
    public let visualProfile: VisualProfile
    public let voiceProfile: VoiceProfile
    public let behaviorMap: BehaviorMap?
    public let house: House?

    public init(
        version: String,
        id: String,
        name: String,
        identity: Identity? = nil,
        visualProfile: VisualProfile,
        voiceProfile: VoiceProfile,
        behaviorMap: BehaviorMap? = nil,
        house: House? = nil
    ) {
        self.version = version
        self.id = id
        self.name = name
        self.identity = identity
        self.visualProfile = visualProfile
        self.voiceProfile = voiceProfile
        self.behaviorMap = behaviorMap
        self.house = house
    }
}

public struct Identity: Codable, Equatable, Sendable {
    public let speciesPrompt: String?
    public let personality: [String]?
    public let tone: String?

    enum CodingKeys: String, CodingKey {
        case speciesPrompt = "speciesPrompt"
        case personality
        case tone
    }

    public init(speciesPrompt: String? = nil, personality: [String]? = nil, tone: String? = nil) {
        self.speciesPrompt = speciesPrompt
        self.personality = personality
        self.tone = tone
    }
}

public struct VisualProfile: Codable, Equatable, Sendable {
    public let runtime: String
    public let supportedRuntimes: [String]?
    public let states: VisualStatesDict
    public let generation: Generation?

    enum CodingKeys: String, CodingKey {
        case runtime
        case supportedRuntimes
        case states
        case generation
    }

    public init(runtime: String, supportedRuntimes: [String]? = nil, states: VisualStatesDict, generation: Generation? = nil) {
        self.runtime = runtime
        self.supportedRuntimes = supportedRuntimes
        self.states = states
        self.generation = generation
    }
}

/// v0.1.0 states 是个 dict，key 是 state 名，value 是相对路径
public struct VisualStatesDict: Codable, Equatable, Sendable {
    public let idle: String
    public let focus: String
    public let happy: String
    public let tired: String
    public let celebrate: String
    // 允许额外 state（schema 没禁；runtime 决定是否渲染）
    public let extras: [String: String]?

    enum CodingKeys: String, CodingKey {
        case idle, focus, happy, tired, celebrate
    }

    public init(
        idle: String,
        focus: String,
        happy: String,
        tired: String,
        celebrate: String,
        extras: [String: String]? = nil
    ) {
        self.idle = idle
        self.focus = focus
        self.happy = happy
        self.tired = tired
        self.celebrate = celebrate
        self.extras = extras
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        func get(_ key: String) throws -> String {
            let k = DynamicKey(stringValue: key)!
            return try container.decode(String.self, forKey: k)
        }
        self.idle = try get("idle")
        self.focus = try get("focus")
        self.happy = try get("happy")
        self.tired = try get("tired")
        self.celebrate = try get("celebrate")
        var extras: [String: String] = [:]
        for key in container.allKeys {
            let value = try container.decode(String.self, forKey: key)
            switch key.stringValue {
            case "idle", "focus", "happy", "tired", "celebrate": continue
            default: extras[key.stringValue] = value
            }
        }
        self.extras = extras.isEmpty ? nil : extras
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        try container.encode(idle, forKey: DynamicKey(stringValue: "idle")!)
        try container.encode(focus, forKey: DynamicKey(stringValue: "focus")!)
        try container.encode(happy, forKey: DynamicKey(stringValue: "happy")!)
        try container.encode(tired, forKey: DynamicKey(stringValue: "tired")!)
        try container.encode(celebrate, forKey: DynamicKey(stringValue: "celebrate")!)
        if let extras {
            for (k, v) in extras {
                try container.encode(v, forKey: DynamicKey(stringValue: k)!)
            }
        }
    }
}

/// DynamicKey 用于上面的 VisualStatesDict 支持任意额外 state
struct DynamicKey: CodingKey {
    var stringValue: String
    init?(stringValue: String) { self.stringValue = stringValue }
    var intValue: Int? { nil }
    init?(intValue: Int) { return nil }
}

public struct Generation: Codable, Equatable, Sendable {
    public let provider: String?
    public let model: String?
    public let prompt: String?
    public let negativePrompt: String?
    public let seed: String?
    public let referenceImages: [String]?
    public let referenceStrength: Double?
    public let size: String?

    enum CodingKeys: String, CodingKey {
        case provider, model, prompt
        case negativePrompt
        case seed
        case referenceImages
        case referenceStrength
        case size
    }

    public init(
        provider: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        negativePrompt: String? = nil,
        seed: String? = nil,
        referenceImages: [String]? = nil,
        referenceStrength: Double? = nil,
        size: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.prompt = prompt
        self.negativePrompt = negativePrompt
        self.seed = seed
        self.referenceImages = referenceImages
        self.referenceStrength = referenceStrength
        self.size = size
    }
}

public struct VoiceProfile: Codable, Equatable, Sendable {
    public let mode: String?
    public let provider: String?
    public let model: String?
    public let voiceId: String?
    public let stylePrompt: String?
    public let sampleSource: String?
    public let consentConfirmed: Bool?

    enum CodingKeys: String, CodingKey {
        case mode, provider, model
        case voiceId
        case stylePrompt
        case sampleSource
        case consentConfirmed
    }

    public init(
        mode: String? = nil,
        provider: String? = nil,
        model: String? = nil,
        voiceId: String? = nil,
        stylePrompt: String? = nil,
        sampleSource: String? = nil,
        consentConfirmed: Bool? = nil
    ) {
        self.mode = mode
        self.provider = provider
        self.model = model
        self.voiceId = voiceId
        self.stylePrompt = stylePrompt
        self.sampleSource = sampleSource
        self.consentConfirmed = consentConfirmed
    }
}

public struct BehaviorMap: Codable, Equatable, Sendable {
    public let `default`: String?
    public let focusStarted: String?
    public let focusCompleted: String?
    public let longWorkSession: String?
    public let taskCompleted: String?
    public let extras: [String: String]?

    enum CodingKeys: String, CodingKey {
        case `default`
        case focusStarted
        case focusCompleted
        case longWorkSession
        case taskCompleted
    }

    public init(
        default: String? = nil,
        focusStarted: String? = nil,
        focusCompleted: String? = nil,
        longWorkSession: String? = nil,
        taskCompleted: String? = nil,
        extras: [String: String]? = nil
    ) {
        self.default = `default`
        self.focusStarted = focusStarted
        self.focusCompleted = focusCompleted
        self.longWorkSession = longWorkSession
        self.taskCompleted = taskCompleted
        self.extras = extras
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)
        func getOpt(_ key: String) throws -> String? {
            let k = DynamicKey(stringValue: key)!
            return try container.decodeIfPresent(String.self, forKey: k)
        }
        self.default = try getOpt("default")
        self.focusStarted = try getOpt("focusStarted")
        self.focusCompleted = try getOpt("focusCompleted")
        self.longWorkSession = try getOpt("longWorkSession")
        self.taskCompleted = try getOpt("taskCompleted")
        var extras: [String: String] = [:]
        for key in container.allKeys {
            let v = try container.decode(String.self, forKey: key)
            switch key.stringValue {
            case "default", "focusStarted", "focusCompleted", "longWorkSession", "taskCompleted": continue
            default: extras[key.stringValue] = v
            }
        }
        self.extras = extras.isEmpty ? nil : extras
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicKey.self)
        if let v = self.default { try container.encode(v, forKey: DynamicKey(stringValue: "default")!) }
        if let v = self.focusStarted { try container.encode(v, forKey: DynamicKey(stringValue: "focusStarted")!) }
        if let v = self.focusCompleted { try container.encode(v, forKey: DynamicKey(stringValue: "focusCompleted")!) }
        if let v = self.longWorkSession { try container.encode(v, forKey: DynamicKey(stringValue: "longWorkSession")!) }
        if let v = self.taskCompleted { try container.encode(v, forKey: DynamicKey(stringValue: "taskCompleted")!) }
        if let extras {
            for (k, v) in extras {
                try container.encode(v, forKey: DynamicKey(stringValue: k)!)
            }
        }
    }
}

public struct House: Codable, Equatable, Sendable {
    public let background: String?
    public let stickers: [HouseItem]?
    public let objects: [HouseItem]?
    public let memories: [HouseItem]?

    public init(background: String? = nil, stickers: [HouseItem]? = nil, objects: [HouseItem]? = nil, memories: [HouseItem]? = nil) {
        self.background = background
        self.stickers = stickers
        self.objects = objects
        self.memories = memories
    }
}

public struct HouseItem: Codable, Equatable, Sendable {
    public let id: String?
    public let kind: String?
    public let assetPath: String?
    public let title: String?
    public let createdAt: String?

    public init(id: String? = nil, kind: String? = nil, assetPath: String? = nil, title: String? = nil, createdAt: String? = nil) {
        self.id = id
        self.kind = kind
        self.assetPath = assetPath
        self.title = title
        self.createdAt = createdAt
    }
}

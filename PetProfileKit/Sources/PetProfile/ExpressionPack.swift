// ExpressionPack.swift
// 表情通道 — 5 必选 state + N 扩展情绪
// Schema 草案第 6 节
//

import Foundation

public struct ExpressionPack: Codable, Equatable, Sendable {
    public let states: ExpressionStates
    public let extendedEmotions: [ExtendedEmotion]?

    enum CodingKeys: String, CodingKey {
        case states
        case extendedEmotions = "extended_emotions"
    }

    public init(states: ExpressionStates, extendedEmotions: [ExtendedEmotion]? = nil) {
        self.states = states
        self.extendedEmotions = extendedEmotions
    }
}

public struct ExpressionStates: Codable, Equatable, Sendable {
    public let idle: ExpressionFace
    public let focus: ExpressionFace
    public let happy: ExpressionFace
    public let tired: ExpressionFace
    public let celebrate: ExpressionFace

    public init(idle: ExpressionFace, focus: ExpressionFace, happy: ExpressionFace, tired: ExpressionFace, celebrate: ExpressionFace) {
        self.idle = idle
        self.focus = focus
        self.happy = happy
        self.tired = tired
        self.celebrate = celebrate
    }
}

public struct ExpressionFace: Codable, Equatable, Sendable {
    public let assetPath: String
    public let blendshapes: [String: BlendshapeValue]?

    enum CodingKeys: String, CodingKey {
        case assetPath = "asset_path"
        case blendshapes
    }

    public init(assetPath: String, blendshapes: [String: BlendshapeValue]? = nil) {
        self.assetPath = assetPath
        self.blendshapes = blendshapes
    }
}

/// blendshape value — 支持数字权重 0..1
public typealias BlendshapeValue = Double

public struct ExtendedEmotion: Codable, Equatable, Sendable {
    public let name: String
    public let assetPath: String
    public let triggerContexts: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case assetPath = "asset_path"
        case triggerContexts = "trigger_contexts"
    }

    public init(name: String, assetPath: String, triggerContexts: [String]? = nil) {
        self.name = name
        self.assetPath = assetPath
        self.triggerContexts = triggerContexts
    }
}

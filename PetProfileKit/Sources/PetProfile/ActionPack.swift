// ActionPack.swift
// 动作通道 — idle + reactions
// Schema 草案第 5 节
//

import Foundation

public struct ActionPack: Codable, Equatable, Sendable {
    public let idle: IdleAction
    public let reactions: [Reaction]

    public init(idle: IdleAction, reactions: [Reaction] = []) {
        self.idle = idle
        self.reactions = reactions
    }
}

public struct IdleAction: Codable, Equatable, Sendable {
    public let name: String
    public let loop: Bool
    public let durationMs: Int
    public let assetPath: String?
    public let assetFormat: AssetFormat?

    enum CodingKeys: String, CodingKey {
        case name, loop
        case durationMs = "duration_ms"
        case assetPath = "asset_path"
        case assetFormat = "asset_format"
    }

    public init(
        name: String,
        loop: Bool = true,
        durationMs: Int,
        assetPath: String? = nil,
        assetFormat: AssetFormat? = nil
    ) {
        self.name = name
        self.loop = loop
        self.durationMs = durationMs
        self.assetPath = assetPath
        self.assetFormat = assetFormat
    }
}

public struct Reaction: Codable, Equatable, Sendable {
    public let trigger: Trigger
    public let name: String
    public let durationMs: Int
    public let assetPath: String?
    public let assetFormat: AssetFormat?
    public let interruptsIdle: Bool
    public let cooldownMs: Int

    enum CodingKeys: String, CodingKey {
        case trigger, name
        case durationMs = "duration_ms"
        case assetPath = "asset_path"
        case assetFormat = "asset_format"
        case interruptsIdle = "interrupts_idle"
        case cooldownMs = "cooldown_ms"
    }

    public init(
        trigger: Trigger,
        name: String,
        durationMs: Int,
        assetPath: String? = nil,
        assetFormat: AssetFormat? = nil,
        interruptsIdle: Bool = true,
        cooldownMs: Int = 500
    ) {
        self.trigger = trigger
        self.name = name
        self.durationMs = durationMs
        self.assetPath = assetPath
        self.assetFormat = assetFormat
        self.interruptsIdle = interruptsIdle
        self.cooldownMs = cooldownMs
    }
}

public enum AssetFormat: String, Codable, Equatable, Sendable, CaseIterable {
    case apng
    case gif
    case mp4Alpha = "mp4-alpha"
    case lottie
    case frameSequence = "frame-sequence"
    case springAnimation = "spring-animation"
    case systemEffect = "system-effect"
}

// Validator.swift
// PetProfile v1 严格校验
//   - 版本必须 1.0.0
//   - id 必须匹配 ^pet_[a-z0-9_]{6,32}$
//   - name 1..32 字符
//   - pitch / speed 0.5..1.5
//   - joke_density 0..1
//   - persona.lore_short 1..280
//   - persona_system_prompt 50..2000
//   - voice_clone_consent.deletable 强制 true
//   - 各 pack 内部约束（durationMs 等）
//   - 5 state asset 路径必填且非空
//
// 不引入第三方 JSON Schema 库；用原生 Codable + 自写 validator。
//

import Foundation

public enum ValidationError: Error, Equatable, CustomStringConvertible {
    case missingField(path: String)
    case invalidValue(path: String, expected: String, actual: String)
    case outOfRange(path: String, min: Double, max: Double, actual: Double)
    case patternMismatch(path: String, pattern: String, actual: String)
    case emptyField(path: String)
    case invalidVersion(expected: String, actual: String)
    case consentMustBeDeletable(path: String)

    public var description: String {
        switch self {
        case .missingField(let p):
            return "missing required field: \(p)"
        case .invalidValue(let p, let e, let a):
            return "invalid value at \(p): expected \(e), got \(a)"
        case .outOfRange(let p, let lo, let hi, let a):
            return "out of range at \(p): expected \(lo)..\(hi), got \(a)"
        case .patternMismatch(let p, let pat, let a):
            return "pattern mismatch at \(p): expected \(pat), got \(a)"
        case .emptyField(let p):
            return "empty field: \(p)"
        case .invalidVersion(let e, let a):
            return "invalid version: expected \(e), got \(a)"
        case .consentMustBeDeletable(let p):
            return "voice_clone_consent.deletable must be true at \(p)"
        }
    }
}

public struct Validator {
    public init() {}

    /// 校验顶层结构 + 嵌套 pack
    public func validate(_ profile: PetProfileV1) throws {
        // version
        if profile.version != .v1_0_0 {
            throw ValidationError.invalidVersion(expected: "1.0.0", actual: profile.version.rawValue)
        }

        // id pattern
        if !profile.id.matchesPattern() {
            throw ValidationError.patternMismatch(
                path: "id",
                pattern: ProfileID.pattern,
                actual: profile.id.raw
            )
        }

        // name 1..32
        try requireNonEmpty(profile.name, path: "name")
        guard profile.name.count <= 32 else {
            throw ValidationError.invalidValue(path: "name", expected: "len<=32", actual: "len=\(profile.name.count)")
        }

        // visual
        try validateVisual(profile.visual)
        // audio
        try validateAudio(profile.audio)
        // action
        try validateAction(profile.action)
        // expression
        try validateExpression(profile.expression)
        // humor
        try validateHumor(profile.humor)
        // persona
        try validatePersona(profile.persona)
    }

    private func validateVisual(_ v: VisualPack) throws {
        try requireNonEmpty(v.states.idle, path: "visual.states.idle")
        try requireNonEmpty(v.states.focus, path: "visual.states.focus")
        try requireNonEmpty(v.states.happy, path: "visual.states.happy")
        try requireNonEmpty(v.states.tired, path: "visual.states.tired")
        try requireNonEmpty(v.states.celebrate, path: "visual.states.celebrate")
        try requirePathRelative(v.states.idle, path: "visual.states.idle")
        try requirePathRelative(v.states.focus, path: "visual.states.focus")
        try requirePathRelative(v.states.happy, path: "visual.states.happy")
        try requirePathRelative(v.states.tired, path: "visual.states.tired")
        try requirePathRelative(v.states.celebrate, path: "visual.states.celebrate")
    }

    private func validateAudio(_ a: AudioPack) throws {
        try requireNonEmpty(a.ttsProvider, path: "audio.tts_provider")
        try requireNonEmpty(a.ttsVoice, path: "audio.tts_voice")
        // voice_style
        try inRange(a.voiceStyle.pitch, lo: 0.5, hi: 1.5, path: "audio.voice_style.pitch")
        try inRange(a.voiceStyle.speed, lo: 0.5, hi: 1.5, path: "audio.voice_style.speed")
        try requireNonEmpty(a.voiceStyle.tone, path: "audio.voice_style.tone")
        // catchphrases
        for (i, c) in a.catchphrases.enumerated() {
            try requireNonEmpty(c.text, path: "audio.catchphrases[\(i)].text")
            guard c.text.count <= 64 else {
                throw ValidationError.invalidValue(path: "audio.catchphrases[\(i)].text", expected: "len<=64", actual: "len=\(c.text.count)")
            }
        }
        // consent
        if let c = a.voiceCloneConsent {
            if c.deletable != true {
                throw ValidationError.consentMustBeDeletable(path: "audio.voice_clone_consent.deletable")
            }
            try requireNonEmpty(c.samplePath, path: "audio.voice_clone_consent.sample_path")
        }
    }

    private func validateAction(_ a: ActionPack) throws {
        try requireNonEmpty(a.idle.name, path: "action.idle.name")
        try inRange(Double(a.idle.durationMs), lo: 500, hi: 10000, path: "action.idle.duration_ms")
        // reactions
        for (i, r) in a.reactions.enumerated() {
            try requireNonEmpty(r.name, path: "action.reactions[\(i)].name")
            try inRange(Double(r.durationMs), lo: 100, hi: 5000, path: "action.reactions[\(i)].duration_ms")
        }
    }

    private func validateExpression(_ e: ExpressionPack) throws {
        let states: [(String, ExpressionFace)] = [
            ("idle", e.states.idle),
            ("focus", e.states.focus),
            ("happy", e.states.happy),
            ("tired", e.states.tired),
            ("celebrate", e.states.celebrate),
        ]
        for (k, face) in states {
            try requireNonEmpty(face.assetPath, path: "expression.states.\(k).asset_path")
        }
        for (i, x) in (e.extendedEmotions ?? []).enumerated() {
            try requireNonEmpty(x.name, path: "expression.extended_emotions[\(i)].name")
            try requireNonEmpty(x.assetPath, path: "expression.extended_emotions[\(i)].asset_path")
        }
    }

    private func validateHumor(_ h: HumorPack) throws {
        let len = h.personaSystemPrompt.count
        guard len >= 50, len <= 2000 else {
            throw ValidationError.invalidValue(
                path: "humor.persona_system_prompt",
                expected: "len in 50..2000",
                actual: "len=\(len)"
            )
        }
        try inRange(h.jokeDensity, lo: 0, hi: 1, path: "humor.joke_density")
    }

    private func validatePersona(_ p: PersonaCard) throws {
        try requireNonEmpty(p.name, path: "persona.name")
        try requireNonEmpty(p.loreShort, path: "persona.lore_short")
        guard p.loreShort.count <= 280 else {
            throw ValidationError.invalidValue(
                path: "persona.lore_short",
                expected: "len<=280",
                actual: "len=\(p.loreShort.count)"
            )
        }
        if let full = p.loreFull, full.count > 4000 {
            throw ValidationError.invalidValue(
                path: "persona.lore_full",
                expected: "len<=4000",
                actual: "len=\(full.count)"
            )
        }
        if let rel = p.relationshipWithUser, rel.count > 280 {
            throw ValidationError.invalidValue(
                path: "persona.relationship_with_user",
                expected: "len<=280",
                actual: "len=\(rel.count)"
            )
        }
    }

    // MARK: - helpers

    private func requireNonEmpty(_ s: String, path: String) throws {
        if s.trimmingCharacters(in: .whitespaces).isEmpty {
            throw ValidationError.emptyField(path: path)
        }
    }

    private func inRange(_ v: Double, lo: Double, hi: Double, path: String) throws {
        if v < lo || v > hi {
            throw ValidationError.outOfRange(path: path, min: lo, max: hi, actual: v)
        }
    }

    /// asset 路径必须相对（不能以 / 开头）
    private func requirePathRelative(_ s: String, path: String) throws {
        if s.hasPrefix("/") {
            throw ValidationError.invalidValue(
                path: path,
                expected: "relative path",
                actual: "absolute path: \(s)"
            )
        }
        if s.contains("..") {
            throw ValidationError.invalidValue(
                path: path,
                expected: "no '..'",
                actual: "contains '..': \(s)"
            )
        }
    }
}

// AudioPack.swift
// 声音通道 — TTS 风格 / catchphrases / 克隆授权元数据
// Schema 草案第 4 节
//

import Foundation

public struct AudioPack: Codable, Equatable, Sendable {
    public let ttsProvider: String
    public let ttsVoice: String
    public let voiceStyle: VoiceStyle
    public let catchphrases: [Catchphrase]
    public let voiceCloneConsent: VoiceCloneConsent?

    enum CodingKeys: String, CodingKey {
        case ttsProvider = "tts_provider"
        case ttsVoice = "tts_voice"
        case voiceStyle = "voice_style"
        case catchphrases
        case voiceCloneConsent = "voice_clone_consent"
    }

    public init(
        ttsProvider: String,
        ttsVoice: String,
        voiceStyle: VoiceStyle,
        catchphrases: [Catchphrase] = [],
        voiceCloneConsent: VoiceCloneConsent? = nil
    ) {
        self.ttsProvider = ttsProvider
        self.ttsVoice = ttsVoice
        self.voiceStyle = voiceStyle
        self.catchphrases = catchphrases
        self.voiceCloneConsent = voiceCloneConsent
    }
}

public struct VoiceStyle: Codable, Equatable, Sendable {
    public let pitch: Double
    public let speed: Double
    public let energy: Energy
    public let tone: String

    public init(pitch: Double = 1.0, speed: Double = 1.0, energy: Energy = .mid, tone: String = "neutral") {
        self.pitch = pitch
        self.speed = speed
        self.energy = energy
        self.tone = tone
    }

    public enum Energy: String, Codable, Equatable, Sendable, CaseIterable {
        case low, mid, high
    }
}

public struct Catchphrase: Codable, Equatable, Sendable {
    public let text: String
    public let trigger: Trigger
    public let cooldownSeconds: Double?
    public let expression: String?

    enum CodingKeys: String, CodingKey {
        case text, trigger, expression
        case cooldownSeconds = "cooldown_seconds"
    }

    public init(text: String, trigger: Trigger, cooldownSeconds: Double? = nil, expression: String? = nil) {
        self.text = text
        self.trigger = trigger
        self.cooldownSeconds = cooldownSeconds
        self.expression = expression
    }
}

/// voice_clone_consent
/// `deletable` 强制 true（schema const=true），所以没有 init 时只能传 true
public struct VoiceCloneConsent: Codable, Equatable, Sendable {
    public let userConfirmsOwnership: Bool
    public let samplePath: String
    public let deletable: Bool  // const true

    enum CodingKeys: String, CodingKey {
        case userConfirmsOwnership = "user_confirms_ownership"
        case samplePath = "sample_path"
        case deletable
    }

    public init(userConfirmsOwnership: Bool, samplePath: String) {
        self.userConfirmsOwnership = userConfirmsOwnership
        self.samplePath = samplePath
        self.deletable = true
    }
}

public enum Trigger: String, Codable, Equatable, Sendable, CaseIterable {
    case click
    case doubleClick = "double_click"
    case drag
    case dragStart = "drag_start"
    case dragEnd = "drag_end"
    case hoverEnter = "hover_enter"
    case hoverLeave = "hover_leave"
    case longPress = "long_press"
    case shakeWindow = "shake_window"
    case focusStart = "focus_start"
    case focusEnd = "focus_end"
    case taskDone = "task_done"
    case random
    case aiReply = "ai_reply"
}

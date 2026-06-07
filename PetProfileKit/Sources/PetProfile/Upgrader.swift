// Upgrader.swift
// PetProfile v0.1.0 → v1.0.0 升级
//
// 映射规则（与 .private/product-design/mvp-pet-schema-draft.md 第 10 节对齐）：
//   - visualProfile.states           → visual.states
//   - visualProfile.runtime           → visual.render_mode（运行时字符串映射 RenderMode 枚举）
//   - visualProfile.supportedRuntimes → visual.supported_render_modes
//   - identity.speciesPrompt + tone   → persona.lore_short（截断到 280）
//   - identity.personality[]          → persona.backstory_tags
//   - voiceProfile.provider           → audio.tts_provider
//   - voiceProfile.voiceId            → audio.tts_voice（占位 "optional-provider-voice-id" 视为空）
//   - voiceProfile.stylePrompt        → audio.voice_style.tone
//   - voiceProfile.consentConfirmed + sampleSource → audio.voice_clone_consent
//       仅当 consentConfirmed=true 且 sampleSource != "none" 时才生成
//   - behaviorMap                     → action.reactions
//       focusStarted/focusCompleted/longWorkSession/taskCompleted 映射成对应 trigger
//   - visualProfile.generation        → 丢弃（v1 不含生成元数据；pet-brain / 生成管线自己存档）
//   - house                           → 丢弃（v1 不含 Pet House；house 是 pet-product / pet-runtime 的运行时层）
//
// 升级是**显式有损**的；调用方拿到的 `UpgradeResult.warnings` 决定是否要再持久化被丢弃的内容。
//

import Foundation

public struct UpgradeResult: Equatable {
    public let profile: PetProfileV1
    public let warnings: [String]
}

public enum Upgrader {
    public static func upgrade(_ old: PetProfileV01) throws -> UpgradeResult {
        var warnings: [String] = []

        // ---- id ----
        let pid = ProfileID(raw: old.id)
        if !pid.matchesPattern() {
            warnings.append("id '\(old.id)' does not match v1 pattern \(ProfileID.pattern); will be re-emitted as-is, but consumers may reject it")
        }

        // ---- visual ----
        let visual = try upgradeVisual(old.visualProfile, warnings: &warnings)

        // ---- audio ----
        let audio = try upgradeAudio(old.voiceProfile, warnings: &warnings)

        // ---- action (from behaviorMap) ----
        let action = upgradeAction(old.behaviorMap, warnings: &warnings)

        // ---- expression ----
        let expression = upgradeExpression(from: old.visualProfile, warnings: &warnings)

        // ---- humor ----
        let humor = upgradeHumor(from: old, warnings: &warnings)

        // ---- persona ----
        let persona = upgradePersona(from: old, warnings: &warnings)

        if old.house != nil {
            warnings.append("v0.1.0 'house' is dropped during upgrade to v1.0.0; v1 packs do not include Pet House data. Persist it via the runtime Pet House layer separately.")
        }
        if old.visualProfile.generation != nil {
            warnings.append("v0.1.0 'visualProfile.generation' is dropped during upgrade; v1 packs do not include generation metadata. The provider-side generation history is owned by pet-brain.")
        }

        let v1 = PetProfileV1(
            version: .v1_0_0,
            minRuntimeVersion: nil,
            id: pid,
            name: old.name,
            createdAt: nil,
            locale: nil,
            visual: visual,
            audio: audio,
            action: action,
            expression: expression,
            humor: humor,
            persona: persona
        )

        // 走 validator 兜底：升级后必须严格通过 v1 schema
        try Validator().validate(v1)

        return UpgradeResult(profile: v1, warnings: warnings)
    }

    // MARK: - per-section

    private static func upgradeVisual(_ v: VisualProfile, warnings: inout [String]) throws -> VisualPack {
        let mode = RenderMode(rawValue: v.runtime) ?? .staticImage
        if RenderMode(rawValue: v.runtime) == nil {
            warnings.append("visualProfile.runtime '\(v.runtime)' is not a v1 RenderMode; defaulting to 'static-image'")
        }
        let supported: [RenderMode]
        if let raw = v.supportedRuntimes {
            supported = raw.compactMap { RenderMode(rawValue: $0) }
            if supported.count != raw.count {
                warnings.append("some entries in visualProfile.supportedRuntimes are not v1 RenderModes and were dropped")
            }
        } else {
            supported = [mode]
        }
        let states = VisualStates(
            idle: v.states.idle,
            focus: v.states.focus,
            happy: v.states.happy,
            tired: v.states.tired,
            celebrate: v.states.celebrate
        )
        return VisualPack(
            renderMode: mode,
            supportedRenderModes: supported.isEmpty ? [mode] : supported,
            transparentAlpha: true,
            idleBreathing: true,
            states: states
        )
    }

    private static func upgradeAudio(_ v: VoiceProfile, warnings: inout [String]) throws -> AudioPack {
        let ttsProvider = v.provider ?? "user-configured"
        // 占位值视为"未配置"，写一个 sentinel 让 validator 通过（v1 只检查 non-empty）
        let ttsVoice: String
        if let vid = v.voiceId, !vid.isEmpty, vid != "optional-provider-voice-id" {
            ttsVoice = vid
        } else {
            ttsVoice = "user-configured"
            warnings.append("v0.1.0 voiceProfile.voiceId is missing or placeholder; audio.tts_voice defaulted to 'user-configured'")
        }

        let style = VoiceStyle(
            pitch: 1.0,
            speed: 1.0,
            energy: .mid,
            tone: v.stylePrompt ?? "neutral"
        )

        // v0.1.0 没有 catchphrases 字段；这里我们无法从 v0.1.0 推断。
        // 升级时 catchphrases 留空，creator 用 v1 编辑器补全。
        let catchphrases: [Catchphrase] = []

        var consent: VoiceCloneConsent? = nil
        if v.consentConfirmed == true, let src = v.sampleSource, src != "none", !src.isEmpty {
            consent = VoiceCloneConsent(userConfirmsOwnership: true, samplePath: src)
        }

        return AudioPack(
            ttsProvider: ttsProvider,
            ttsVoice: ttsVoice,
            voiceStyle: style,
            catchphrases: catchphrases,
            voiceCloneConsent: consent
        )
    }

    private static func upgradeAction(_ b: BehaviorMap?, warnings: inout [String]) -> ActionPack {
        let idle = IdleAction(
            name: "breathe",
            loop: true,
            durationMs: 2000,
            assetPath: nil,
            assetFormat: .apng
        )

        var reactions: [Reaction] = []
        if let b = b {
            if b.focusStarted != nil {
                reactions.append(Reaction(trigger: .focusStart, name: "focus-look", durationMs: 600))
            }
            if b.focusCompleted != nil {
                reactions.append(Reaction(trigger: .focusEnd, name: "focus-cheer", durationMs: 800))
            }
            if b.longWorkSession != nil {
                reactions.append(Reaction(trigger: .shakeWindow, name: "tired-sigh", durationMs: 600))
            }
            if b.taskCompleted != nil {
                reactions.append(Reaction(trigger: .taskDone, name: "task-happy", durationMs: 500))
            }
            if let extras = b.extras {
                warnings.append("behaviorMap has extra keys \(Array(extras.keys).sorted()); only standard triggers are upgraded")
            }
        }
        if reactions.isEmpty {
            warnings.append("behaviorMap missing or empty; action.reactions is empty (only idle action is preserved)")
        }

        return ActionPack(idle: idle, reactions: reactions)
    }

    private static func upgradeExpression(from v: VisualProfile, warnings: inout [String]) -> ExpressionPack {
        // v0.1.0 复用 visual.states 作为 5 必选 expression 路径
        // v1 允许额外 emotion，v0.1.0 没有这部分，留空
        let states = ExpressionStates(
            idle: ExpressionFace(assetPath: v.states.idle),
            focus: ExpressionFace(assetPath: v.states.focus),
            happy: ExpressionFace(assetPath: v.states.happy),
            tired: ExpressionFace(assetPath: v.states.tired),
            celebrate: ExpressionFace(assetPath: v.states.celebrate)
        )
        return ExpressionPack(states: states, extendedEmotions: nil)
    }

    private static func upgradeHumor(from old: PetProfileV01, warnings: inout [String]) -> HumorPack {
        // v0.1.0 没有 humor 通道；升级时给一个 placeholder prompt，
        // 让 validator 通过（>= 50 字符）。用户后续可改。
        // 选用 identity.tone / personality 拼出 base 描述。
        let tone = old.identity?.tone ?? "neutral"
        let personality = (old.identity?.personality ?? []).joined(separator: ", ")
        let species = old.identity?.speciesPrompt ?? "your personal desktop companion"
        let base = "\(old.name) 是一只住在你工位的桌面宠物（\(species)）。它的性格标签：\(personality.isEmpty ? "n/a" : personality)。说话风格：\(tone)。保持 1-2 句以内，不抢话，不主动给建议。"
        // 兜底长度：validator 要求 >= 50
        let prompt: String
        if base.count >= 50 {
            prompt = base
        } else {
            prompt = base + " 你安静、克制、只在用户主动找你时回应。"
        }
        return HumorPack(
            humorStyle: .gentle,
            personaSystemPrompt: prompt,
            jokeDensity: 0.05,
            memePool: nil,
            selfDeprecationTopics: nil
        )
    }

    private static func upgradePersona(from old: PetProfileV01, warnings: inout [String]) -> PersonaCard {
        let tone = old.identity?.tone ?? ""
        let species = old.identity?.speciesPrompt ?? ""
        var loreParts: [String] = []
        if !species.isEmpty { loreParts.append(species) }
        if !tone.isEmpty { loreParts.append("说话风格：\(tone)") }
        let rawLore = loreParts.joined(separator: "。")
        let loreShort: String
        if rawLore.isEmpty {
            loreShort = "一只陪你待在桌面上的小宠物。\(old.name) 不太说话，但在。"
            warnings.append("identity is empty; persona.lore_short is a generic placeholder; user should rewrite")
        } else if rawLore.count <= 280 {
            loreShort = rawLore
        } else {
            loreShort = String(rawLore.prefix(280))
            warnings.append("persona.lore_short truncated to 280 chars during upgrade")
        }
        return PersonaCard(
            name: old.name,
            loreShort: loreShort,
            loreFull: nil,
            relationshipWithUser: "你的桌面陪伴。",
            recurringMotifs: nil,
            backstoryTags: old.identity?.personality
        )
    }
}

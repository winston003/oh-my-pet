// PromptBuilder.swift
// System prompt 拼装 — 把 4 段拼成给 LLM 的完整 system prompt
//
// 拼装优先级（hard rule，来自 pet-brain agent.md）：
//   1. humor.persona_system_prompt（**主干**，决定 pet 说话方式）
//   2. persona.lore_short + relationship_with_user + recurring_motifs（**身份**）
//   3. voice_style.tone / pitch / speed / energy（**声音风格**）
//   4. 5 通道 context（currentState / lastAction / 哪些 pack 启用）
//   5. 收尾：joke_density 提醒 + 5 通道输出格式约定
//
// 公共 API：
//   - buildSystemPrompt(profile:) — 给 Brain 喂 LLM
//   - buildUserPrompt(context:) — 把当前 state + last action + user input 拼成 user turn
//
// 不做：
//   - 不做 token 计数 / 截断（真 LLM 接入时再加）
//   - 不做 i18n（pet 内部用 zh-CN，prompt 一律中英混合）
//   - 不写 hardcoded pet 名字 / lore（profile-driven）
//

import Foundation
import PetProfile
import PetProfileRuntime

// MARK: - PromptContext

/// Brain 喂 PromptBuilder 的"当前世界状态"。
///
/// lastAction 填的是 reaction name 字符串（不是 ActionReaction 本身），
/// 避免 PromptBuilder 接触 runtime 层的具体 type。
public struct PromptContext: Equatable, Sendable {
    public let currentState: VisualState
    public let lastAction: String?
    public let userInput: String

    public init(
        currentState: VisualState = .idle,
        lastAction: String? = nil,
        userInput: String
    ) {
        self.currentState = currentState
        self.lastAction = lastAction
        self.userInput = userInput
    }
}

// MARK: - PromptBuilder

public enum PromptBuilder {

    // MARK: - System prompt

    /// 拼出完整 system prompt。
    /// 返回 multi-line 文本，结构清晰、单元测试可逐段断言。
    public static func buildSystemPrompt(profile: LoadedPetProfile) -> String {
        let manifest = profile.manifest

        // 1. Humor persona（主干）
        let humorSection = """
        ## 你的人设（来自 humor pack — 主干）

        \(manifest.humor.personaSystemPrompt)

        - 语气标签：\(manifest.humor.humorStyle.rawValue)
        - 玩梗密度：\(formatJokeDensity(manifest.humor.jokeDensity))（0 = 不玩梗；1 = 一直玩）
        """

        // 2. Persona 身份
        var personaLines: [String] = []
        personaLines.append("- 名字：\(manifest.persona.name)")
        personaLines.append("- 一句话背景：\(manifest.persona.loreShort)")
        if let rel = manifest.persona.relationshipWithUser, !rel.isEmpty {
            personaLines.append("- 跟用户的关系：\(rel)")
        }
        if let motifs = manifest.persona.recurringMotifs, !motifs.isEmpty {
            personaLines.append("- 反复出现的小细节：" + motifs.joined(separator: "、"))
        }

        let personaSection = """
        ## 你的身份（来自 persona card）

        \(personaLines.joined(separator: "\n"))
        """

        // 3. Voice style
        let voice = manifest.audio.voiceStyle
        let voiceSection = """
        ## 你的声音风格（来自 audio pack — 决定 TTS 调性）

        - 音色：\(voice.tone)
        - pitch: \(formatDouble(voice.pitch))（0.5 = 低；1.0 = 中；1.5 = 高）
        - speed: \(formatDouble(voice.speed))（0.5 = 慢；1.0 = 中；1.5 = 快）
        - energy: \(voice.energy.rawValue)
        - TTS provider: \(manifest.audio.ttsProvider)
        - TTS voice: \(manifest.audio.ttsVoice)
        """

        // 4. 5 通道 context
        let channelsSection = """
        ## 5 通道能力（你一次回复可以同时驱动多个通道）

        - 🎤 **voice** — 用 audio pack 的 catchphrases 库（text + trigger + expression）选一句或造新句
        - 🏃 **action** — 用 action pack 的 reactions（trigger + name + duration_ms）选一个或造新名
        - 😀 **expression** — 5 base state（idle / focus / happy / tired / celebrate），决定宠物现在长什么样
        - 😂 **humor** — 已经在主干里，joke_density 决定玩梗频率
        - 📖 **story** — 已经在 persona 段，recurring_motifs 是你"老朋友"的暗号
        """

        // 5. 收尾：5 通道输出格式约定
        let formatSection = """
        ## 输出格式（重要）

        只输出 **一个 JSON 对象**，不要 Markdown 代码块、不要解释、不要客套话。结构如下：

        ```
        {
          "text": "你说的话（必填，≤ 64 字）",
          "expression": "happy" | "idle" | "focus" | "tired" | "celebrate" | null,
          "action": "reaction name（action.reactions 里的 name 字段）" | null,
          "audio_catchphrase": "audio.catchphrases 里的 text 字段" | null
        }
        ```

        - `text` 必填。
        - `expression` 省略 / null = 保持当前 state 不变。
        - `action` 用 action.reactions 的 `name` 字段值；不在列表里就 null。
        - `audio_catchphrase` 用 audio.catchphrases 的 `text` 字段值；不在列表里就 null。
        """

        return [
            humorSection,
            personaSection,
            voiceSection,
            channelsSection,
            formatSection,
        ].joined(separator: "\n\n")
    }

    // MARK: - User prompt

    /// 把"当前世界 + user input"拼成 user turn。
    /// 让 LLM 知道现在是什么 state、上一个 reaction 是什么、用户说了啥。
    public static func buildUserPrompt(context: PromptContext) -> String {
        var lines: [String] = []
        lines.append("## 当前世界状态")
        lines.append("- visual state: \(context.currentState.rawValue)")
        if let last = context.lastAction, !last.isEmpty {
            lines.append("- last action: \(last)")
        } else {
            lines.append("- last action: (none)")
        }
        lines.append("")
        lines.append("## User 说")
        lines.append(context.userInput)
        lines.append("")
        lines.append("## 请按 5 通道格式回复（text / expression / action / audio_catchphrase）")
        return lines.joined(separator: "\n")
    }

    // MARK: - helpers

    private static func formatJokeDensity(_ d: Double) -> String {
        // 0.0 / 0.05 / 0.4 / 0.5 / 1.0 之类
        return String(format: "%.2f", d)
    }

    private static func formatDouble(_ d: Double) -> String {
        return String(format: "%.2f", d)
    }

    // MARK: - Selection Assistant prompt 编排（P2-L-3）

    /// 给 Selection Assistant 编排 system + user 段。
    ///   - pet 注入 4 段：name / species / humor style / story tone
    ///   - pet = nil：fallback 到通用 "Be a helpful, concise assistant" 系统提示
    ///   - "honesty boundary" 段**强制**注入到 system 段（spec §3.1 P4 诚实感知）：
    ///     pet 绝不能假装看到用户屏幕 / 文件 / apps 之外的内容
    ///   - 不开 5 通道输出格式（属 Brain.respond 的契约；Selection 是工具，不是 pet 在聊天）
    ///
    /// 行为契约（任务描述 + spec P7）：
    ///   - ask       → "User asks (in {appName}): {selectedText}"
    ///   - translate → "Translate this text: {selectedText}"（**不**指定目标语言；让 provider 决定）
    ///   - explain   → "Explain this: {selectedText}"
    ///   - summarize → "Summarize this: {selectedText}"
    ///   - rewrite   → "Rewrite this: {selectedText}"
    ///
    /// 决策说明（**不**让 SelectionCoordinator 拼字符串再传）：
    ///   - TextCompletionRequest 加 `petProfile: PetProfileSummary?` 字段，
    ///     provider 内部自己调 `PromptBuilder.buildSelectionPrompt` 拼。
    ///   - 理由 1：pet 人设注入 + 边界声明是 prompt 编排的一部分；
    ///     让 provider 调编排层，UI 不需要知道 pet 字段如何映射 → 关注点分离
    ///   - 理由 2：真 OpenAI HTTP 接入（P2-N）时，provider 还要把 system/user
    ///     序列化进 Chat Completions API body；拼接一次、统一走 provider
    ///     内部 helper（p2_n_provider_http_client）即可
    ///   - 理由 3：UI 端不重复实现 pet 字段 → 字符串映射；测试覆盖一次 provider 即可
    public static func buildSelectionPrompt(
        request: TextCompletionRequest,
        pet: PetProfileSummary?
    ) -> SelectionPromptContext {
        // 1. system 段
        let system: String
        let petNameForUI: String?
        let humorStyleForUI: String?

        if let pet {
            petNameForUI = pet.name
            humorStyleForUI = pet.humorStyle
            system = """
            You are \(pet.name), a \(pet.species) companion.
            Humor style: \(pet.humorStyle)
            Tone: \(pet.storyTone)
            Always respond briefly (1-3 sentences unless asked for more).
            Never break character. Never claim to access the user's screen, files, or apps beyond the provided context.
            """
        } else {
            petNameForUI = nil
            humorStyleForUI = nil
            system = "You are a helpful, concise assistant. Always respond briefly (1-3 sentences unless asked for more). Never claim to access the user's screen, files, or apps beyond the provided context."
        }

        // 2. user 段（action-specific）
        let appName = request.appContext?.appName ?? "unknown app"
        let user: String
        switch request.action {
        case .ask:
            user = "User asks (in \(appName)): \(request.selectedText)"
        case .translate:
            // 注：spec 明确不指定目标语言；让 provider 决定。
            // （OpenAI / Claude / Stub 都接受 "Translate this text" 然后自己定 target）
            user = "Translate this text: \(request.selectedText)"
        case .explain:
            user = "Explain this: \(request.selectedText)"
        case .summarize:
            user = "Summarize this: \(request.selectedText)"
        case .rewrite:
            user = "Rewrite this: \(request.selectedText)"
        }

        return SelectionPromptContext(
            system: system,
            user: user,
            petName: petNameForUI,
            humorStyle: humorStyleForUI
        )
    }
}

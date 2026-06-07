// Brain.swift
// Brain — Brain API 核心
//
// 责任：
//   - 拼 system prompt + user prompt → 调 LLM
//   - 解析 LLM output → BrainResponse
//   - 把 BrainResponse 喂给 ChannelDispatcher.dispatch（多通道调度）
//   - 维护 currentState / lastAction（每轮 respond 后更新）
//
// 设计决策：
//   - **currentState 初值 = .idle**，由 Brain 自己管；不依赖外部 panel
//   - **lastAction 维护的是 reaction name 字符串**，跟 prompt 里 last action 字段对齐
//   - **expression fallback**：LLM 没指定 expression → 用 currentState
//   - **action name lookup**：LLM 指定 action = "jelly-bounce" → 在 profile.action.reactions 查
//     name 命中的那个，包成 ActionReaction.from(_:withTrigger: .aiReply)
//   - **audio text lookup**：LLM 指定 audio_catchphrase = "嘛" → 在 profile.audio.catchphrases
//     查 text 命中的那个，包成 AudioCatchphrase.from(_)
//   - **lookup miss**：LLM 给了不存在的 action / audio 名字 → 该通道 nil（不让 panic）
//   - **dispatcher 调一次**：expression → action → audio 顺序由 ChannelDispatcher 决定
//   - **BYOK 边界**：Brain 不接 provider/model；只接 LLMProvider。
//     以后真 provider 接入时，构造 brain 时把 OpenAILLM / ClaudeLLM 塞进来即可
//
// 不做：
//   - 不接 Keychain / 不接网络 / 不接真 LLM
//   - 不直接调 NSPanel / SpringAnimation（用 ChannelDispatcher 抽象）
//   - 不维护跨 session 记忆（短期 / 长期记忆是 P2-C）
//   - 不做 token 计数 / 流式输出（真 LLM 接入时再加）
//

import Foundation
import PetProfile
import PetProfileRuntime

public final class Brain {

    public let profile: LoadedPetProfile
    public let llm: LLMProvider
    public let dispatcher: ChannelDispatcher

    /// 当前 visual state。每次 respond 后更新。
    public private(set) var currentState: VisualState

    /// 上一个 dispatch 的 action reaction name（供下次 prompt 引用）。
    public private(set) var lastAction: String?

    /// 累计 respond 次数（debug / 测试用）。
    public private(set) var respondCount: Int = 0

    public init(
        profile: LoadedPetProfile,
        llm: LLMProvider,
        dispatcher: ChannelDispatcher,
        initialState: VisualState = .idle
    ) {
        self.profile = profile
        self.llm = llm
        self.dispatcher = dispatcher
        self.currentState = initialState
    }

    // MARK: - public API

    /// 喂一段 user input 给 Brain。流程：
    ///   1. 拼 user prompt（当前 state + last action + user input）
    ///   2. 调 LLM
    ///   3. 解析 → BrainResponse
    ///   4. 解析里的 action name / audio text 在 profile 里 lookup
    ///   5. 调 ChannelDispatcher.dispatch（expression 必传，action/audio 可选）
    ///   6. 更新 currentState / lastAction
    public func respond(to userInput: String) throws -> BrainResponse {
        respondCount += 1

        // 1. 拼 prompts
        let sys = systemPrompt()
        let userCtx = PromptContext(
            currentState: currentState,
            lastAction: lastAction,
            userInput: userInput
        )
        let usr = PromptBuilder.buildUserPrompt(context: userCtx)
        let fullPrompt = sys + "\n\n" + usr

        // 2. 调 LLM
        let raw = try llm.complete(prompt: fullPrompt)

        // 3. 解析
        let parsed = try MockLLMResponseParser.parse(raw)

        // 4. 解析 action name / audio text → 在 profile 里 lookup
        let resolvedAction = resolveAction(named: parsed.action)
        let resolvedAudio = resolveAudio(text: parsed.audio)

        // 5. expression fallback: 解析不到 → 保持 current state
        let resolvedExpression: VisualState
        if let eRaw = parsed.expression, let e = VisualState.parse(eRaw) {
            resolvedExpression = e
        } else {
            resolvedExpression = currentState
        }

        let response = BrainResponse(
            text: parsed.text,
            expression: resolvedExpression,
            action: resolvedAction,
            audioCatchphrase: resolvedAudio
        )

        // 6. dispatch（expression 必传，action/audio 可选）
        dispatcher.dispatch(
            expression: resolvedExpression,
            action: resolvedAction,
            audio: resolvedAudio
        )

        // 7. 更新 state
        currentState = resolvedExpression
        if let a = resolvedAction {
            lastAction = a.name
        }

        return response
    }

    /// debug / 测试用：返回完整 system prompt（可看实际拼出来的样子）。
    public func systemPrompt() -> String {
        return PromptBuilder.buildSystemPrompt(profile: profile)
    }

    // MARK: - profile lookup

    /// 在 profile.action.reactions 里按 name 查找 reaction。
    /// - Returns: 命中的 ActionReaction（trigger 记为 .aiReply），或 nil（未命中 / LLM 传 null）
    private func resolveAction(named: String?) -> ActionReaction? {
        guard let name = named, !name.isEmpty else { return nil }
        for r in profile.manifest.action.reactions {
            if r.name == name {
                return ActionReaction.from(r, withTrigger: .aiReply)
            }
        }
        return nil
    }

    /// 在 profile.audio.catchphrases 里按 text 查找 catchphrase。
    /// - Returns: 命中的 AudioCatchphrase，或 nil
    private func resolveAudio(text: String?) -> AudioCatchphrase? {
        guard let t = text, !t.isEmpty else { return nil }
        for cp in profile.manifest.audio.catchphrases {
            if cp.text == t {
                return AudioCatchphrase.from(cp)
            }
        }
        return nil
    }
}

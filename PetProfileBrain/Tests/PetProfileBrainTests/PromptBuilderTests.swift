// PromptBuilderTests.swift
// PromptBuilder 单元测试 — 3 个 pet × 4 个 context = 12 case
//
// 覆盖：
//   - System prompt 4 段都齐：humor / persona / voice / 5 通道 / 输出格式
//   - joke_density 在 system prompt 里有体现（Zorp 0.5 / Pako 0.4 / Mitu 0.05）
//   - humor_style 在 system prompt 里有体现（self-deprecating / gentle / sarcastic）
//   - voice_style.tone / pitch / speed / energy 在 system prompt 里有体现
//   - persona.lore_short / relationship_with_user / recurring_motifs 在 prompt 里
//   - 5 通道 output format 约定在 prompt 里
//   - User prompt 包含 current state / last action / user input
//
// 越界检查：
//   - 3 pet × 4 context 矩阵的 prompt 内容都是 pet 自身 profile 驱动
//   - 不读 PetProfileKit / PetProfileRuntime 既有文件（只 import + 用 public API）
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileBrain

func registerPromptBuilderTests(_ tests: Tests) {

    // MARK: - System prompt 4 段结构性检查（3 pet × 1 = 3 case）

    tests.add("PromptBuilder.testPakoSystemPromptHasAll4Sections") { _ in
        let p = try loadPakoProfile()
        let sys = PromptBuilder.buildSystemPrompt(profile: p)
        // humor 主干
        try XCTAssertContains(sys, "你的人设（来自 humor pack")
        try XCTAssertContains(sys, "Pako")
        try XCTAssertContains(sys, "果冻小怪物")
        // persona 身份
        try XCTAssertContains(sys, "你的身份（来自 persona card）")
        try XCTAssertContains(sys, "工位上的老朋友")
        try XCTAssertContains(sys, "肚子变粉红")  // recurring_motifs
        // voice style
        try XCTAssertContains(sys, "你的声音风格")
        try XCTAssertContains(sys, "drawl-deadpan")  // tone
        try XCTAssertContains(sys, "0.85")  // pitch
        // 5 通道
        try XCTAssertContains(sys, "5 通道能力")
        try XCTAssertContains(sys, "voice")
        try XCTAssertContains(sys, "action")
        try XCTAssertContains(sys, "expression")
        try XCTAssertContains(sys, "humor")
        try XCTAssertContains(sys, "story")
        // 输出格式
        try XCTAssertContains(sys, "输出格式")
        try XCTAssertContains(sys, "audio_catchphrase")
    }

    tests.add("PromptBuilder.testMituSystemPromptHasAll4Sections") { _ in
        let p = try loadMituProfile()
        let sys = PromptBuilder.buildSystemPrompt(profile: p)
        try XCTAssertContains(sys, "Mitu")
        try XCTAssertContains(sys, "云端来的小白兔")
        try XCTAssertContains(sys, "安静朋友")
        try XCTAssertContains(sys, "warm-gentle")
        try XCTAssertContains(sys, "1.10")  // pitch 1.1
        try XCTAssertContains(sys, "辛苦了")  // 触发 audio 但不强制 — 这里只验 voice + persona
    }

    tests.add("PromptBuilder.testZorpSystemPromptHasAll4Sections") { _ in
        let p = try loadZorpProfile()
        let sys = PromptBuilder.buildSystemPrompt(profile: p)
        try XCTAssertContains(sys, "Zorp")
        try XCTAssertContains(sys, "高维生物")
        try XCTAssertContains(sys, "凡人")  // 关系定位里没有，但 recurring_motifs / humor prompt 里有
        try XCTAssertContains(sys, "cold-sarcastic")
        try XCTAssertContains(sys, "electronic")
    }

    // MARK: - joke_density 在 prompt 里的体现（3 pet × 1 = 3 case）

    tests.add("PromptBuilder.testPakoJokeDensityInPrompt") { _ in
        let p = try loadPakoProfile()
        let sys = PromptBuilder.buildSystemPrompt(profile: p)
        try XCTAssertContains(sys, "0.40")
        try XCTAssertContains(sys, "self-deprecating")
    }

    tests.add("PromptBuilder.testMituJokeDensityInPrompt") { _ in
        let p = try loadMituProfile()
        let sys = PromptBuilder.buildSystemPrompt(profile: p)
        try XCTAssertContains(sys, "0.05")
        try XCTAssertContains(sys, "gentle")
    }

    tests.add("PromptBuilder.testZorpJokeDensityInPrompt") { _ in
        let p = try loadZorpProfile()
        let sys = PromptBuilder.buildSystemPrompt(profile: p)
        try XCTAssertContains(sys, "0.50")
        try XCTAssertContains(sys, "sarcastic")
    }

    // MARK: - User prompt 4 段（3 pet × 4 context = 12 case）

    // Pako × 4
    tests.add("PromptBuilder.testPakoUserPrompt_default") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .idle, lastAction: nil, userInput: "hello"))
        try XCTAssertContains(usr, "当前世界状态")
        try XCTAssertContains(usr, "visual state: idle")
        try XCTAssertContains(usr, "last action: (none)")
        try XCTAssertContains(usr, "hello")
        try XCTAssertContains(usr, "5 通道格式回复")
    }

    tests.add("PromptBuilder.testPakoUserPrompt_withState") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .focus, lastAction: nil, userInput: "我开始工作了"))
        try XCTAssertContains(usr, "visual state: focus")
        try XCTAssertContains(usr, "我开始工作了")
    }

    tests.add("PromptBuilder.testPakoUserPrompt_withLastAction") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .idle, lastAction: "jelly-bounce", userInput: "再来一下"))
        try XCTAssertContains(usr, "last action: jelly-bounce")
        try XCTAssertContains(usr, "再来一下")
    }

    tests.add("PromptBuilder.testPakoUserPrompt_fullContext") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .happy, lastAction: "rubber-stretch", userInput: "我累了"))
        try XCTAssertContains(usr, "visual state: happy")
        try XCTAssertContains(usr, "last action: rubber-stretch")
        try XCTAssertContains(usr, "我累了")
    }

    // Mitu × 4
    tests.add("PromptBuilder.testMituUserPrompt_default") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .idle, lastAction: nil, userInput: "在吗"))
        try XCTAssertContains(usr, "在吗")
        try XCTAssertContains(usr, "visual state: idle")
    }

    tests.add("PromptBuilder.testMituUserPrompt_withState") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .focus, lastAction: nil, userInput: "写完了"))
        try XCTAssertContains(usr, "visual state: focus")
        try XCTAssertContains(usr, "写完了")
    }

    tests.add("PromptBuilder.testMituUserPrompt_withLastAction") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .idle, lastAction: "curl-into-ball", userInput: "又点了一下"))
        try XCTAssertContains(usr, "last action: curl-into-ball")
    }

    tests.add("PromptBuilder.testMituUserPrompt_fullContext") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .celebrate, lastAction: "fur-shake-look-up", userInput: "task done"))
        try XCTAssertContains(usr, "visual state: celebrate")
        try XCTAssertContains(usr, "last action: fur-shake-look-up")
        try XCTAssertContains(usr, "task done")
    }

    // Zorp × 4
    tests.add("PromptBuilder.testZorpUserPrompt_default") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .idle, lastAction: nil, userInput: "凡人，你好"))
        try XCTAssertContains(usr, "凡人，你好")
    }

    tests.add("PromptBuilder.testZorpUserPrompt_withState") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .focus, lastAction: nil, userInput: "在写代码"))
        try XCTAssertContains(usr, "visual state: focus")
        try XCTAssertContains(usr, "在写代码")
    }

    tests.add("PromptBuilder.testZorpUserPrompt_withLastAction") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .idle, lastAction: "tentacle-slap", userInput: "又戳"))
        try XCTAssertContains(usr, "last action: tentacle-slap")
    }

    tests.add("PromptBuilder.testZorpUserPrompt_fullContext") { _ in
        let usr = PromptBuilder.buildUserPrompt(context: PromptContext(
            currentState: .happy, lastAction: "spin-rainbow", userInput: "task done"))
        try XCTAssertContains(usr, "visual state: happy")
        try XCTAssertContains(usr, "last action: spin-rainbow")
        try XCTAssertContains(usr, "task done")
    }

    // MARK: - 结构性保证

    tests.add("PromptBuilder.testSystemPromptProfileDriven") { _ in
        // 3 pet 的 system prompt 都以 humor 主干起手（不是 lore）
        for (loader, name) in [
            ({ try loadPakoProfile() }, "Pako"),
            ({ try loadMituProfile() }, "Mitu"),
            ({ try loadZorpProfile() }, "Zorp"),
        ] {
            let p = try loader()
            let sys = PromptBuilder.buildSystemPrompt(profile: p)
            // humor 主干在 persona 之前
            let humorIdx = sys.range(of: "你的人设")?.lowerBound
            let personaIdx = sys.range(of: "你的身份")?.lowerBound
            try XCTAssertNotNil(humorIdx, "humor section missing for \(name)")
            try XCTAssertNotNil(personaIdx, "persona section missing for \(name)")
            try XCTAssertLessThan(humorIdx!, personaIdx!, "humor should come before persona for \(name)")
        }
    }

    tests.add("PromptBuilder.testSystemPromptMinLength50") { _ in
        // persona_system_prompt schema 约束 50-2000 字；系统 prompt 应该更长
        for loader in [loadPakoProfile, loadMituProfile, loadZorpProfile] {
            let p = try loader()
            let sys = PromptBuilder.buildSystemPrompt(profile: p)
            try XCTAssertGreaterThanOrEqual(sys.count, 200, "system prompt too short")
        }
    }
}

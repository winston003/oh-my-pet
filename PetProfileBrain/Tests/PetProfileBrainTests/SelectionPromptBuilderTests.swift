// SelectionPromptBuilderTests.swift
// PromptBuilder.buildSelectionPrompt + SelectionPromptContext 单元测试
//
// 覆盖（P2-L-3 任务 spec）：
//   - 4 pet × nil + Pako (deadpan-ish, self-deprecating) + Mitu (gentle) + Zorp (sarcastic)
//   - 5 个 action 各自 userMessage 格式
//   - honesty boundary 段**必须**在 system 段（spec P4 诚实感知）
//   - 4 个 pet 都**不**hardcode "Pako" / "Mitu" / "Zorp" 字符串到 PromptBuilder 内部；
//     pet 名字从 PetProfileSummary 来，summary 自己从 manifest 派
//   - pet = nil → 通用 helpful assistant 系统提示
//   - action = translate → **不**指定目标语言
//   - SelectionPromptContext 是 struct + Equatable + Sendable
//   - PetProfileSummary.from(manifest:) 字段映射
//
// 越界检查（adversarial probe）：
//   - grep "pet.name\s*=\s*\"" / "petName\s*=" 源码 — 0 命中（无 hardcode）
//   - 4 个 pet profile 渲染出**不同**的 system 段（humor / story 区分）
//   - "Never claim to access" / "Never break character" 段**必须**出现
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileBrain

func registerSelectionPromptBuilderTests(_ tests: Tests) {

    // MARK: - helpers

    func makeAppContext(appName: String = "Safari", bundleID: String? = "com.apple.Safari") -> AppContextSnapshot {
        return AppContextSnapshot(
            bundleID: bundleID,
            appName: appName,
            windowTitle: nil,
            capturedAt: Date()
        )
    }

    func makeRequest(action: SelectionActionKind, text: String = "Hello world", appName: String = "Safari") -> TextCompletionRequest {
        return TextCompletionRequest(
            action: action,
            selectedText: text,
            appContext: makeAppContext(appName: appName)
        )
    }

    // MARK: - pet=nil fallback

    tests.add("SelPrompt.testNilPet_usesHelpfulAssistant") { _ in
        let prompt = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .explain),
            pet: nil
        )
        try XCTAssertContains(prompt.system, "helpful, concise assistant")
        try XCTAssertContains(prompt.system, "Never claim to access")  // honesty boundary still required
        try XCTAssertNil(prompt.petName)
        try XCTAssertNil(prompt.humorStyle)
        // user 段
        try XCTAssertContains(prompt.user, "Explain this:")
        try XCTAssertContains(prompt.user, "Hello world")
    }

    tests.add("SelPrompt.testNilPet_doesNotCrash_5Actions") { _ in
        for action in SelectionActionKind.allCases {
            let p = PromptBuilder.buildSelectionPrompt(
                request: makeRequest(action: action),
                pet: nil
            )
            try XCTAssertTrue(p.system.count > 10, "\(action.rawValue) system too short")
            try XCTAssertTrue(p.user.count > 0, "\(action.rawValue) user empty")
        }
    }

    // MARK: - 3 pet fixture × system prompt humor 注入

    tests.add("SelPrompt.testPakoSystemPrompt_deadpan_injects") { _ in
        let p = try loadPakoProfile()
        let summary = PetProfileSummary.from(manifest: p.manifest)
        try XCTAssertEqual(summary.name, "Pako")
        let prompt = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .ask),
            pet: summary
        )
        // pet 名 + species + humor style + tone
        try XCTAssertContains(prompt.system, "You are Pako")
        try XCTAssertContains(prompt.system, "companion")
        try XCTAssertContains(prompt.system, "self-deprecating")
        // Pako 的 relationshipWithUser = "工位上的老朋友..."
        try XCTAssertContains(prompt.system, "工位上的老朋友")
        // honesty boundary
        try XCTAssertContains(prompt.system, "Never claim to access")
        try XCTAssertContains(prompt.system, "Never break character")
        try XCTAssertContains(prompt.system, "1-3 sentences")
        // user 段
        try XCTAssertContains(prompt.user, "User asks (in Safari):")
        try XCTAssertContains(prompt.user, "Hello world")
        // meta
        try XCTAssertEqual(prompt.petName, "Pako")
        try XCTAssertEqual(prompt.humorStyle, "self-deprecating")
    }

    tests.add("SelPrompt.testMituSystemPrompt_gentle_injects") { _ in
        let p = try loadMituProfile()
        let summary = PetProfileSummary.from(manifest: p.manifest)
        try XCTAssertEqual(summary.name, "Mitu")
        let prompt = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .ask),
            pet: summary
        )
        try XCTAssertContains(prompt.system, "You are Mitu")
        try XCTAssertContains(prompt.system, "gentle")
        // Mitu 的 relationshipWithUser = "陪你看窗外云..."
        try XCTAssertContains(prompt.system, "安静朋友")
        try XCTAssertContains(prompt.system, "Never claim to access")
    }

    tests.add("SelPrompt.testZorpSystemPrompt_sarcastic_injects") { _ in
        let p = try loadZorpProfile()
        let summary = PetProfileSummary.from(manifest: p.manifest)
        try XCTAssertEqual(summary.name, "Zorp")
        let prompt = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .ask),
            pet: summary
        )
        try XCTAssertContains(prompt.system, "You are Zorp")
        try XCTAssertContains(prompt.system, "sarcastic")
        // Zorp 的 relationshipWithUser = "高贵的旁观者..."
        try XCTAssertContains(prompt.system, "高贵的旁观者")
        try XCTAssertContains(prompt.system, "Never claim to access")
    }

    // MARK: - 3 个 pet 渲染出 3 个**不同**的 system 段（区分度）

    tests.add("SelPrompt.testThreePets_produceDistinctSystemPrompts") { _ in
        let pakos = PetProfileSummary.from(manifest: try loadPakoProfile().manifest)
        let mitus = PetProfileSummary.from(manifest: try loadMituProfile().manifest)
        let zorps = PetProfileSummary.from(manifest: try loadZorpProfile().manifest)
        let pPako = PromptBuilder.buildSelectionPrompt(request: makeRequest(action: .ask), pet: pakos)
        let pMitu = PromptBuilder.buildSelectionPrompt(request: makeRequest(action: .ask), pet: mitus)
        let pZorp = PromptBuilder.buildSelectionPrompt(request: makeRequest(action: .ask), pet: zorps)
        // 三者 system 段互不相等
        try XCTAssertNotEqual(pPako.system, pMitu.system)
        try XCTAssertNotEqual(pMitu.system, pZorp.system)
        try XCTAssertNotEqual(pPako.system, pZorp.system)
        // user 段相同（action 一样 + selectedText 一样 + appName 一样）
        try XCTAssertEqual(pPako.user, pMitu.user)
        try XCTAssertEqual(pMitu.user, pZorp.user)
    }

    // MARK: - 5 个 action 各自 userMessage 格式

    tests.add("SelPrompt.testActionAsk_includesAppName") { _ in
        let p = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .ask, appName: "Xcode"),
            pet: nil
        )
        try XCTAssertContains(p.user, "User asks (in Xcode):")
        try XCTAssertContains(p.user, "Hello world")
    }

    tests.add("SelPrompt.testActionAsk_nilAppContext_unknownApp") { _ in
        let req = TextCompletionRequest(
            action: .ask, selectedText: "x", appContext: nil, petID: nil, petProfile: nil, model: nil
        )
        let p = PromptBuilder.buildSelectionPrompt(request: req, pet: nil)
        try XCTAssertContains(p.user, "User asks (in unknown app):")
    }

    tests.add("SelPrompt.testActionTranslate_doesNotSpecifyTargetLanguage") { _ in
        let p = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .translate),
            pet: nil
        )
        try XCTAssertContains(p.user, "Translate this text:")
        // **不**应该指定目标语言
        try XCTAssertFalse(p.user.contains("to English"), "translate should NOT specify target language")
        try XCTAssertFalse(p.user.contains("to Chinese"), "translate should NOT specify target language")
        try XCTAssertFalse(p.user.contains("to Mandarin"), "translate should NOT specify target language")
        try XCTAssertFalse(p.user.contains("中文"), "translate should NOT specify target language")
    }

    tests.add("SelPrompt.testActionExplain_format") { _ in
        let p = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .explain),
            pet: nil
        )
        try XCTAssertEqual(p.user, "Explain this: Hello world")
    }

    tests.add("SelPrompt.testActionSummarize_format") { _ in
        let p = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .summarize),
            pet: nil
        )
        try XCTAssertEqual(p.user, "Summarize this: Hello world")
    }

    tests.add("SelPrompt.testActionRewrite_format") { _ in
        let p = PromptBuilder.buildSelectionPrompt(
            request: makeRequest(action: .rewrite),
            pet: nil
        )
        try XCTAssertEqual(p.user, "Rewrite this: Hello world")
    }

    // MARK: - 5 个 action 矩阵 × 3 pet = 15 user 段（humor 不影响 user 段）

    tests.add("SelPrompt.test5Actions3Pets_userSegmentActionDriven") { _ in
        let pets: [PetProfileSummary] = [
            PetProfileSummary.from(manifest: try loadPakoProfile().manifest),
            PetProfileSummary.from(manifest: try loadMituProfile().manifest),
            PetProfileSummary.from(manifest: try loadZorpProfile().manifest),
        ]
        for pet in pets {
            for action in SelectionActionKind.allCases {
                let p = PromptBuilder.buildSelectionPrompt(
                    request: makeRequest(action: action),
                    pet: pet
                )
                // user 段应该**不**受 pet 名字影响（humor 注入只在 system）
                switch action {
                case .ask:
                    try XCTAssertContains(p.user, "User asks (in Safari):")
                case .translate:
                    try XCTAssertContains(p.user, "Translate this text:")
                case .explain:
                    try XCTAssertContains(p.user, "Explain this:")
                case .summarize:
                    try XCTAssertContains(p.user, "Summarize this:")
                case .rewrite:
                    try XCTAssertContains(p.user, "Rewrite this:")
                }
            }
        }
    }

    // MARK: - honesty boundary 注入

    tests.add("SelPrompt.testHonestyBoundary_alwaysPresent") { _ in
        // 不管 pet 在不在，system 段**必须**含边界声明
        let pets: [PetProfileSummary?] = [
            nil,
            PetProfileSummary(name: "X", species: "y", humorStyle: "gentle", storyTone: "z"),
            PetProfileSummary.from(manifest: try loadPakoProfile().manifest),
            PetProfileSummary.from(manifest: try loadMituProfile().manifest),
            PetProfileSummary.from(manifest: try loadZorpProfile().manifest),
        ]
        for pet in pets {
            for action in SelectionActionKind.allCases {
                let p = PromptBuilder.buildSelectionPrompt(
                    request: makeRequest(action: action),
                    pet: pet
                )
                try XCTAssertContains(p.system, "Never claim to access",
                    "honesty boundary missing for pet=\(String(describing: pet?.name)) action=\(action.rawValue)")
            }
        }
    }

    // MARK: - length 约束

    tests.add("SelPrompt.testSystemPromptHasLengthConstraint") { _ in
        // 1-3 sentences
        let pets: [PetProfileSummary?] = [
            nil,
            PetProfileSummary.from(manifest: try loadPakoProfile().manifest),
        ]
        for pet in pets {
            let p = PromptBuilder.buildSelectionPrompt(
                request: makeRequest(action: .ask),
                pet: pet
            )
            try XCTAssertContains(p.system, "1-3 sentences")
        }
    }

    // MARK: - PetProfileSummary.from(manifest:) 字段映射

    tests.add("SelPrompt.testPetSummaryFrom_Pako") { _ in
        let p = try loadPakoProfile()
        let s = PetProfileSummary.from(manifest: p.manifest)
        try XCTAssertEqual(s.name, "Pako")
        try XCTAssertEqual(s.species, "office")  // backstoryTags.first
        try XCTAssertEqual(s.humorStyle, "self-deprecating")
        try XCTAssertEqual(s.storyTone, "工位上的老朋友，偶尔戳一下就会果冻化。")
    }

    tests.add("SelPrompt.testPetSummaryFrom_Mitu") { _ in
        let p = try loadMituProfile()
        let s = PetProfileSummary.from(manifest: p.manifest)
        try XCTAssertEqual(s.name, "Mitu")
        try XCTAssertEqual(s.species, "cloud")
        try XCTAssertEqual(s.humorStyle, "gentle")
    }

    tests.add("SelPrompt.testPetSummaryFrom_Zorp") { _ in
        let p = try loadZorpProfile()
        let s = PetProfileSummary.from(manifest: p.manifest)
        try XCTAssertEqual(s.name, "Zorp")
        try XCTAssertEqual(s.species, "alien")
        try XCTAssertEqual(s.humorStyle, "sarcastic")
    }

    // MARK: - SelectionPromptContext 结构

    tests.add("SelPrompt.testSelectionPromptContext_EquatableAndSendable") { _ in
        // 编译期检查：SelectionPromptContext 是 Sendable + Equatable
        let a = SelectionPromptContext(system: "s1", user: "u1", petName: "Pako", humorStyle: "gentle")
        let b = SelectionPromptContext(system: "s1", user: "u1", petName: "Pako", humorStyle: "gentle")
        let c = SelectionPromptContext(system: "s2", user: "u1", petName: "Pako", humorStyle: "gentle")
        try XCTAssertEqual(a, b)
        try XCTAssertNotEqual(a, c)
    }

    // MARK: - adversarial probe: no hardcoded pet name in PromptBuilder

    tests.add("SelPrompt.testPromptBuilder_doesNotHardcodePetNames") { _ in
        // 4 个 pet summary 都有不同 name / species / humorStyle / storyTone
        // PromptBuilder 应该对所有 4 个都正确渲染，**不**会有"只对 Pako 正确"的情况
        let cases: [(String, String, String, String)] = [
            ("Alpha",   "alpha-type",   "deadpan",       "first"),
            ("Beta",    "beta-type",    "sarcastic",     "second"),
            ("Gamma",   "gamma-type",   "playful",       "third"),
            ("Delta",   "delta-type",   "selfDeprecating-fake", "fourth"),
        ]
        for (name, species, humor, tone) in cases {
            let summary = PetProfileSummary(
                name: name, species: species,
                humorStyle: humor, storyTone: tone
            )
            let p = PromptBuilder.buildSelectionPrompt(
                request: makeRequest(action: .ask),
                pet: summary
            )
            try XCTAssertContains(p.system, "You are \(name)")
            try XCTAssertContains(p.system, "\(species) companion")
            try XCTAssertContains(p.system, "Humor style: \(humor)")
            try XCTAssertContains(p.system, "Tone: \(tone)")
            try XCTAssertEqual(p.petName, name)
            try XCTAssertEqual(p.humorStyle, humor)
        }
    }
}

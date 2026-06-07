// MockLLMTests.swift
// MockLLM + MockLLMResponseParser 单元测试 — 12-15 fixture 解析
//
// 覆盖：
//   - 15 个 fixture 都能 load + 字段解析正确
//   - text 必填；可选字段缺省 / null 解析成 nil
//   - MockLLM.complete() 关键字命中：相同关键字输入多次 → 同一 fixture
//   - MockLLM.complete() 关键字未命中 → 走轮转
//   - MockLLMResponseParser：malformed / empty text / 各种 null 组合
//
// 不做：
//   - 不测 LLM provider 网络行为（mock only）
//   - 不测 Keychain / network
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileBrain

func registerMockLLMTests(_ tests: Tests) {

    // MARK: - Fixture load + 字段解析（15 fixture，每个 1 case = 15 case）

    tests.add("MockLLM.testFixture_pako_default") { _ in
        let f = try TestMockLLMLoader.load("pako-default")
        try XCTAssertEqual(f.text, "嗯——这样啊，没事慢慢来。")
        try XCTAssertEqual(f.expression, "happy")
        try XCTAssertEqual(f.action, "jelly-bounce")
        try XCTAssertNil(f.audioCatchphrase)
    }

    tests.add("MockLLM.testFixture_pako_joke") { _ in
        let f = try TestMockLLMLoader.load("pako-joke")
        try XCTAssertEqual(f.text, "嘛，又周五了吗。")
        try XCTAssertEqual(f.action, "jelly-bounce")
        try XCTAssertEqual(f.audioCatchphrase, "嘛，又周五了吗")
    }

    tests.add("MockLLM.testFixture_pako_comfort") { _ in
        let f = try TestMockLLMLoader.load("pako-comfort")
        try XCTAssertEqual(f.text, "嗯——这样啊。")
        try XCTAssertEqual(f.audioCatchphrase, "没事，慢慢来")
    }

    tests.add("MockLLM.testFixture_pako_tired") { _ in
        let f = try TestMockLLMLoader.load("pako-tired")
        try XCTAssertEqual(f.text, "又熬过去了。")
        try XCTAssertEqual(f.expression, "tired")
        try XCTAssertNil(f.action)  // null → nil
        try XCTAssertEqual(f.audioCatchphrase, "我比你会摸鱼")
    }

    tests.add("MockLLM.testFixture_pako_minimal") { _ in
        let f = try TestMockLLMLoader.load("pako-minimal")
        try XCTAssertEqual(f.text, "哦。")
        try XCTAssertNil(f.expression)
        try XCTAssertNil(f.action)
        try XCTAssertNil(f.audioCatchphrase)
    }

    tests.add("MockLLM.testFixture_mitu_default") { _ in
        let f = try TestMockLLMLoader.load("mitu-default")
        try XCTAssertEqual(f.text, "嗯——这样啊。")
        try XCTAssertEqual(f.expression, "happy")
        try XCTAssertEqual(f.audioCatchphrase, "嗯嗯")
    }

    tests.add("MockLLM.testFixture_mitu_comfort") { _ in
        let f = try TestMockLLMLoader.load("mitu-comfort")
        try XCTAssertEqual(f.text, "嗯——辛苦了。")
        try XCTAssertEqual(f.action, "fur-shake-look-up")
        try XCTAssertEqual(f.audioCatchphrase, "辛苦了")
    }

    tests.add("MockLLM.testFixture_mitu_focus") { _ in
        let f = try TestMockLLMLoader.load("mitu-focus")
        try XCTAssertEqual(f.text, "嗯。")
        try XCTAssertEqual(f.expression, "focus")
    }

    tests.add("MockLLM.testFixture_mitu_celebrate") { _ in
        let f = try TestMockLLMLoader.load("mitu-celebrate")
        try XCTAssertEqual(f.text, "嗯。")
        try XCTAssertEqual(f.expression, "celebrate")
        try XCTAssertEqual(f.action, "curl-into-ball")
    }

    tests.add("MockLLM.testFixture_mitu_minimal") { _ in
        let f = try TestMockLLMLoader.load("mitu-minimal")
        try XCTAssertEqual(f.text, "嗯。")
        try XCTAssertNil(f.action)
        try XCTAssertNil(f.audioCatchphrase)
    }

    tests.add("MockLLM.testFixture_zorp_default") { _ in
        let f = try TestMockLLMLoader.load("zorp-default")
        try XCTAssertEqual(f.text, "凡人，你又来了。")
        try XCTAssertEqual(f.action, "tentacle-slap")
        try XCTAssertEqual(f.audioCatchphrase, "凡人，你又来了")
    }

    tests.add("MockLLM.testFixture_zorp_joke") { _ in
        let f = try TestMockLLMLoader.load("zorp-joke")
        try XCTAssertEqual(f.text, "这 bug 不赖我。")
        try XCTAssertEqual(f.audioCatchphrase, "这 bug 不赖我")
    }

    tests.add("MockLLM.testFixture_zorp_sarcastic") { _ in
        let f = try TestMockLLMLoader.load("zorp-sarcastic")
        try XCTAssertEqual(f.text, "凡人，你还在写 bug 啊。")
        try XCTAssertEqual(f.expression, "tired")
        try XCTAssertEqual(f.audioCatchphrase, "我比你想得好看")
    }

    tests.add("MockLLM.testFixture_zorp_celebrate") { _ in
        let f = try TestMockLLMLoader.load("zorp-celebrate")
        try XCTAssertEqual(f.text, "凡人，辛苦了——勉强。")
        try XCTAssertEqual(f.expression, "celebrate")
        try XCTAssertEqual(f.action, "spin-rainbow")
    }

    tests.add("MockLLM.testFixture_zorp_minimal") { _ in
        let f = try TestMockLLMLoader.load("zorp-minimal")
        try XCTAssertEqual(f.text, "哼。")
        try XCTAssertEqual(f.expression, "idle")
    }

    // MARK: - loadAll（3 pet prefix）

    tests.add("MockLLM.testLoadAllPako") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "pako-")
        try XCTAssertEqual(fs.count, 5, "expected 5 pako fixtures, got \(fs.count)")
        for f in fs {
            try XCTAssertTrue(f.text.count > 0)
        }
    }

    tests.add("MockLLM.testLoadAllMitu") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "mitu-")
        try XCTAssertEqual(fs.count, 5)
    }

    tests.add("MockLLM.testLoadAllZorp") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "zorp-")
        try XCTAssertEqual(fs.count, 5)
    }

    // MARK: - MockLLM.complete() 关键字匹配

    tests.add("MockLLM.testComplete_keywordMatch_pako") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "pako-")
        let llm = MockLLM(fixtures: fs)
        // "周五" 命中 pako-joke
        let raw = try llm.complete(prompt: "user 说：今天周五，写完代码")
        let parsed = try MockLLMResponseParser.parse(raw)
        try XCTAssertEqual(parsed.text, "嘛，又周五了吗。")
        try XCTAssertEqual(parsed.action, "jelly-bounce")
    }

    tests.add("MockLLM.testComplete_keywordMatch_zorp") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "zorp-")
        let llm = MockLLM(fixtures: fs)
        // "bug" 命中 zorp-joke
        let raw = try llm.complete(prompt: "user 说：这个 bug 写不出来了")
        let parsed = try MockLLMResponseParser.parse(raw)
        try XCTAssertEqual(parsed.text, "这 bug 不赖我。")
        try XCTAssertEqual(parsed.audio, "这 bug 不赖我")
    }

    tests.add("MockLLM.testComplete_keywordMatch_mitu") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "mitu-")
        let llm = MockLLM(fixtures: fs)
        // "task done" 命中 mitu-celebrate
        let raw = try llm.complete(prompt: "user 说：task done")
        let parsed = try MockLLMResponseParser.parse(raw)
        try XCTAssertEqual(parsed.text, "嗯。")
        try XCTAssertEqual(parsed.expression, "celebrate")
    }

    // MARK: - MockLLM 轮转 fallback

    tests.add("MockLLM.testComplete_keywordMiss_rotates") { _ in
        let fs = try TestMockLLMLoader.loadAll(prefix: "pako-")
        let llm = MockLLM(fixtures: fs)
        // 完全不命中关键字 → 走轮转：5 次返回应该都 parse 通过
        var seenTexts: Set<String> = []
        for _ in 0..<fs.count {
            let raw = try llm.complete(prompt: "user 说：zzz 完全无关键字的输入 xyzqq")
            let parsed = try MockLLMResponseParser.parse(raw)
            seenTexts.insert(parsed.text)
        }
        // 5 次轮转覆盖 5 个 fixture，text 至少不全相同
        try XCTAssertGreaterThanOrEqual(seenTexts.count, 3, "rotation should produce at least 3 distinct texts, got \(seenTexts.count)")
    }

    tests.add("MockLLM.testComplete_emptyFixtures_throws") { _ in
        let llm = MockLLM(fixtures: [])
        try XCTAssertThrowsError { _ = try llm.complete(prompt: "anything") }
    }

    // MARK: - MockLLMResponseParser 边界

    tests.add("MockLLM.testParser_textRequired") { _ in
        // 缺 text → 抛 malformedResponse
        let bad = "{\"expression\": \"happy\"}"
        try XCTAssertThrowsError { _ = try MockLLMResponseParser.parse(bad) }
    }

    tests.add("MockLLM.testParser_malformedJSON") { _ in
        try XCTAssertThrowsError { _ = try MockLLMResponseParser.parse("not json at all") }
    }

    tests.add("MockLLM.testParser_emptyText") { _ in
        let bad = "{\"text\": \"\"}"
        try XCTAssertThrowsError { _ = try MockLLMResponseParser.parse(bad) }
    }

    tests.add("MockLLM.testParser_nullFields") { _ in
        // 所有可选字段都是 null
        let raw = "{\"text\": \"hi\", \"expression\": null, \"action\": null, \"audio_catchphrase\": null}"
        let parsed = try MockLLMResponseParser.parse(raw)
        try XCTAssertEqual(parsed.text, "hi")
        try XCTAssertNil(parsed.expression)
        try XCTAssertNil(parsed.action)
        try XCTAssertNil(parsed.audio)
    }

    tests.add("MockLLM.testParser_skipsUnderscoreKeys") { _ in
        // 解析时遇到 _match_keywords 不能爆错（JSON 包含非业务字段）
        let raw = "{\"text\": \"hi\", \"_match_keywords\": [\"foo\"]}"
        let parsed = try MockLLMResponseParser.parse(raw)
        try XCTAssertEqual(parsed.text, "hi")
    }
}

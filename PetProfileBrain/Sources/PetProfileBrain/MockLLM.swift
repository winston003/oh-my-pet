// MockLLM.swift
// Mock LLM provider — 从 fixture JSON 文件读 LLM response，按 user input 关键字匹配。
//
// 设计要点：
//   - **不接真 LLM**。所有 response 来自 Tests/Fixtures/ 下的 JSON
//   - **fixture 文件名规则**：<pet>-<scene>.json（e.g. pako-joke.json, mitu-comfort.json）
//   - **fixture 内容**：一个 JSON object，跟 BrainResponse 字段一一对应
//     {"text": "...", "expression": "happy", "action": "jelly-bounce", "audio_catchphrase": "嘛"}
//     可选字段：expression / action / audio_catchphrase（缺省 = null）
//   - **匹配策略**：fixture 包含一个 `_match_keywords` 字段（test 时使用；production mock 忽略），
//     Brain 调 complete(prompt) 时：
//       1) 看 user input 里的关键字命中哪个 fixture 的 _match_keywords
//       2) 命中 → 返回该 fixture 的 JSON 字符串
//       3) 没命中 → 走 default 行为（按 pet 分轮 / 返回 minimal response）
//
// 不做：
//   - 不接 network / 不读 Keychain / 不引入第三方 LLM 库
//   - 不做"如果 LLM 说啥就返回啥"（那是 production provider 的事；mock 走 fixture）
//

import Foundation
import PetProfile
import PetProfileRuntime

// MARK: - MockLLMResponse

/// 单条 fixture 的解析后形态。
/// 对应一个 JSON 文件（Tests/Fixtures/<pet>-<scene>.json）。
public struct MockLLMFixture: Codable, Equatable, Sendable {
    /// LLM 的回复文本（必填）
    public let text: String
    /// 期望切到的 visual state。缺省 = null（保持当前 state）
    public let expression: String?
    /// 期望触发的 action reaction name。缺省 = null
    public let action: String?
    /// 期望播放的 audio catchphrase text。缺省 = null
    public let audioCatchphrase: String?
    /// 测试用关键字列表（user input 包含任一即命中）。production 走 default 轮转
    public let matchKeywords: [String]?

    enum CodingKeys: String, CodingKey {
        case text, expression, action
        case audioCatchphrase = "audio_catchphrase"
        case matchKeywords = "_match_keywords"
    }
}

// MARK: - MockLLM

public final class MockLLM: LLMProvider {

    private let fixtures: [MockLLMFixture]
    private var rotationIndex: Int = 0

    /// 用 fixture 数组构造（test / production 都可调）
    public init(fixtures: [MockLLMFixture]) {
        self.fixtures = fixtures
    }

    /// 同步 mock：按 user input 关键字匹配 fixture
    public func complete(prompt: String) throws -> String {
        if fixtures.isEmpty {
            throw LLMError.emptyResponse
        }

        // 关键：只匹配 user input 段（"## User 说\n... \n\n## 请按 5 通道格式回复" 之间的内容），
        // 不匹配 system prompt 段（system 里包含 pet 自己的 lore、relationship_with_user 里的
        // "凡人" / "嗯" 之类，会污染关键字匹配）
        let userInput = MockLLM.extractUserInput(from: prompt)

        // 1. 关键字匹配：fixture._match_keywords 包含的任一关键字在 user input 里出现即命中
        let lowerUserInput = userInput.lowercased()
        for fixture in fixtures {
            guard let kws = fixture.matchKeywords, !kws.isEmpty else { continue }
            for kw in kws {
                if lowerUserInput.contains(kw.lowercased()) {
                    return encode(fixture: fixture)
                }
            }
        }

        // 2. 没命中：走轮转 default 行为（确保测试稳定，多次 call → 多个 fixture 都覆盖到）
        let chosen = fixtures[rotationIndex % fixtures.count]
        rotationIndex += 1
        return encode(fixture: chosen)
    }

    // MARK: - helpers

    /// 从完整 prompt 里抽出 user input 段（"## User 说\n..." 的内容）。
    /// - 找不到 marker 时返回全文（保持向后兼容，caller 自己处理）
    public static func extractUserInput(from prompt: String) -> String {
        let marker = "## User 说"
        guard let markerRange = prompt.range(of: marker) else { return prompt }
        let after = prompt[markerRange.upperBound...]
        // 跳过 marker 后面的换行
        var trimmed = after
        while let first = trimmed.first, first == "\n" || first == " " {
            trimmed = trimmed.dropFirst()
        }
        // 找下一个 "\n##" 段（"## 请按 5 通道格式回复" 之前的内容）
        if let nextSection = trimmed.range(of: "\n##") {
            return String(trimmed[..<nextSection.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encode(fixture: MockLLMFixture) -> String {
        // 用 JSONEncoder 把 fixture 转回完整 JSON 字符串（含 _match_keywords），
        // 这样 Brain 解析时需要用 MockLLMResponseParser（跳过 _match_keywords）。
        // 这里直接返 fixture 的"业务字段 JSON"，不带 _match_keywords。
        var dict: [String: Any] = ["text": fixture.text]
        if let e = fixture.expression { dict["expression"] = e }
        else { dict["expression"] = NSNull() }
        if let a = fixture.action { dict["action"] = a }
        else { dict["action"] = NSNull() }
        if let ac = fixture.audioCatchphrase { dict["audio_catchphrase"] = ac }
        else { dict["audio_catchphrase"] = NSNull() }
        let data = (try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

// MARK: - MockLLMResponseParser

/// 把 LLM raw text 解析成结构化字段。
/// **不**做 channel 调度 / 不查 profile —— 那都是 Brain 的事。
public enum MockLLMResponseParser {

    /// 解析成功 → 返回 (text, expressionRaw, actionRaw, audioRaw)
    /// 任意字段缺省 / null → 对应字段为 nil
    public static func parse(_ raw: String) throws -> (text: String, expression: String?, action: String?, audio: String?) {
        guard let data = raw.data(using: .utf8) else {
            throw LLMError.malformedResponse(rawText: raw)
        }
        // 用 JSONSerialization（不依赖 schema-driven Codable），
        // 因为 LLM output 里 action 可能是 null；Codable 解 null 容易踩坑
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.malformedResponse(rawText: raw)
        }
        // text 必填
        guard let text = obj["text"] as? String, !text.isEmpty else {
            throw LLMError.malformedResponse(rawText: raw)
        }
        return (
            text: text,
            expression: stringOrNil(obj["expression"]),
            action: stringOrNil(obj["action"]),
            audio: stringOrNil(obj["audio_catchphrase"])
        )
    }

    private static func stringOrNil(_ v: Any?) -> String? {
        if v == nil || v is NSNull { return nil }
        return v as? String
    }
}

// MARK: - Fixture loading helper (test target uses this)
//
// `Bundle.module` 只在 test target 的资源里能找到，library target 不带。
// 所以 loader 实际实现在 test target 的 `TestMockLLMLoader.swift`。
// 这里只暴露 fixture struct + parser，loader 留给测试侧。

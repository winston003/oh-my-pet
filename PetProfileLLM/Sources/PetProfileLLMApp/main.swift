// main.swift
// PetProfileLLMApp 命令行入口
//
// 行为：
//   1. fixture mode（默认）：用 PetProfileBrain.MockLLM 跑 Brain.respond 端到端
//   2. real mode（带 --provider <name> 参数）：
//      a. 从 Keychain 读对应 provider 的 API key
//      b. 构造真 AsyncLLMProvider
//      c. 包成 SyncLLMProviderAdapter
//      d. 跑 Brain.respond
//   3. 打印每次 respond 的 text + expression + action + audio
//   4. exit 0
//
// 关键约束（per task spec）：
//   - "fixture mode（无真 key）→ fallback 到 MockLLM 跑全链路"
//   - 真 LLM 端到端需 BYOK + 真实 API key；本 main 不在没真 key 时调真 LLM
//   - 不要求 GUI 实际显示；只验证 provider 构造 + Brain.respond 跑通
//
// 用法：
//   swift run PetProfileLLMApp                # fixture mode（MockLLM）
//   swift run PetProfileLLMApp --provider openai   # 试图用真 OpenAI（keychain 找不到 → 走 fixture + 警告）
//   swift run PetProfileLLMApp --provider claude   # 同上
//   swift run PetProfileLLMApp --provider openai-compatible:http://localhost:11434 --model llama3
//
// Exit code:
//   0 = success（fixture 或真模式都算成功）
//   1 = failure（Brain.respond 抛错 / profile 加载失败 / 工厂参数错）
//

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain
import PetProfileLLM

// MARK: - banner

func printBanner(_ msg: String) {
    print("[llm-app] \(msg)")
}

// MARK: - CLI 解析

struct CLIArgs {
    var provider: String?  // nil = fixture mode
    var model: String?
    var pet: String = "pako"  // 3 pet 之一；默认 pako
    var input: String = "周五了！"  // 默认 user input（pako-joke fixture 关键字匹配）
}

func parseArgs() -> CLIArgs {
    var args = CLIArgs()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--provider":
            i += 1
            if i < argv.count { args.provider = argv[i] }
        case "--model":
            i += 1
            if i < argv.count { args.model = argv[i] }
        case "--pet":
            i += 1
            if i < argv.count { args.pet = argv[i] }
        case "--input":
            i += 1
            if i < argv.count { args.input = argv[i] }
        default:
            break
        }
        i += 1
    }
    return args
}

// MARK: - 入口

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let args = parseArgs()
printBanner("pet: \(args.pet) | input: \"\(args.input)\"")

// 1. 加载 pet profile（用 PetProfileLLM test target 的 fixture；先尝试 source tree 路径，
//    找不到再尝试 Bundle.module — main 跑时不走 test bundle）
func locateProfile(name: String) throws -> URL {
    // main 跑时 fixtures 在 source tree
    let candidates: [URL] = [
        URL(fileURLWithPath: "/Users/whilewon/workspace/oh-my-pet/PetProfileBrain/Tests/PetProfileBrainTests/Fixtures/Profiles/\(name).json"),
        URL(fileURLWithPath: "/Users/whilewon/workspace/oh-my-pet/PetProfileLLM/Tests/PetProfileLLMTests/Fixtures/Profiles/\(name).json")
    ]
    for c in candidates {
        if FileManager.default.fileExists(atPath: c.path) {
            return c
        }
    }
    throw NSError(
        domain: "PetProfileLLMApp", code: 404,
        userInfo: [NSLocalizedDescriptionKey: "no profile fixture found for '\(name)'"]
    )
}

let profileURL = try locateProfile(name: "\(args.pet)-v1.0.0")
// 复制到 tmp 避免 loader 在 source tree 写占位 PNG
let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("pet-llm-app-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
let tmpProfile = tmpRoot.appendingPathComponent("\(args.pet)-v1.0.0.json")
try FileManager.default.copyItem(at: profileURL, to: tmpProfile)
let profile = try PetProfileLoader().loadProfile(from: tmpProfile)
printBanner("profile loaded: \(profile.manifest.name) (\(profile.manifest.humor.humorStyle.rawValue), jokeDensity=\(profile.manifest.humor.jokeDensity))")

// 2. 构造 LLM provider
let llm: LLMProvider
let mode: String

if let providerName = args.provider {
    do {
        // real mode：尝试从 keychain 拉 key + 构造真 provider
        let asyncProvider = try RealLLMFactory.create(
            provider: providerName,
            model: args.model
        )
        llm = SyncLLMProviderAdapter(wrapping: asyncProvider)
        mode = "real"
        printBanner("[OK] real provider: \(asyncProvider.name)")
    } catch {
        // keychain 找不到 / factory 错 → fallback 到 fixture
        FileHandle.standardError.write(Data("[llm-app] WARN: real mode fallback to fixture: \(error)\n".utf8))
        llm = try makeMockLLM(pet: args.pet)
        mode = "fixture-fallback"
        printBanner("[OK] fixture fallback: MockLLM with \(args.pet) fixtures")
    }
} else {
    llm = try makeMockLLM(pet: args.pet)
    mode = "fixture"
    printBanner("[OK] fixture mode: MockLLM with \(args.pet) fixtures")
}

// 3. 构造 Brain（用 BrainTestSink 隔离 NSPanel）
let sink = AppDemoSink()
let dispatcher = ChannelDispatcher(sink: sink)
let brain = Brain(profile: profile, llm: llm, dispatcher: dispatcher)

do {
    let response = try brain.respond(to: args.input)
    printBanner("---")
    printBanner("[mode=\(mode)] respond count: \(brain.respondCount)")
    printBanner("text: \(response.text)")
    printBanner("expression: \(response.expression?.rawValue ?? "nil")")
    printBanner("action: \(response.action?.name ?? "nil")")
    printBanner("audio: \(response.audioCatchphrase?.text ?? "nil")")
    printBanner("sink: expressionCalls=\(sink.expressionCalls.map { $0.rawValue })")
    printBanner("sink: actionCalls=\(sink.actionCalls.map { $0.name })")
    printBanner("sink: audioCalls=\(sink.audioCalls)")
    printBanner("[OK] PetProfileLLMApp: Brain 端到端跑通")
    exit(0)
} catch {
    FileHandle.standardError.write(Data("[llm-app] FAIL: \(error)\n".utf8))
    exit(1)
}

// MARK: - helpers

func makeMockLLM(pet: String) throws -> MockLLM {
    // main 跑时不通过 Bundle.module 找 fixture；直接读 source tree
    let prefix = "\(pet)-"
    let candidates: [URL] = [
        URL(fileURLWithPath: "/Users/whilewon/workspace/oh-my-pet/PetProfileBrain/Tests/PetProfileBrainTests/Fixtures/LLMResponses"),
        URL(fileURLWithPath: "/Users/whilewon/workspace/oh-my-pet/PetProfileLLM/Tests/PetProfileLLMTests/Fixtures/LLMResponses")
    ]
    for dir in candidates {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let matched = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
        if !matched.isEmpty {
            var fixtures: [MockLLMFixture] = []
            for url in matched.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let data = try Data(contentsOf: url)
                let f = try JSONDecoder().decode(MockLLMFixture.self, from: data)
                fixtures.append(f)
            }
            return MockLLM(fixtures: fixtures)
        }
    }
    throw NSError(
        domain: "PetProfileLLMApp", code: 404,
        userInfo: [NSLocalizedDescriptionKey: "no LLMResponse fixture found for pet '\(pet)'"]
    )
}

/// 跟 BrainTests 里的 BrainTestSink 等价的 ChannelSink；main 不需要 @testable 也能 import
final class AppDemoSink: ChannelSink {
    var expressionCalls: [VisualState] = []
    var actionCalls: [ActionReaction] = []
    var audioCalls: [String] = []
    var audioNilCount: Int = 0

    func playExpression(_ state: VisualState) { expressionCalls.append(state) }
    func playAction(_ reaction: ActionReaction) { actionCalls.append(reaction) }
    func playAudio(_ catchphrase: AudioCatchphrase?) {
        if let cp = catchphrase { audioCalls.append(cp.text) }
        else { audioNilCount += 1 }
    }
}

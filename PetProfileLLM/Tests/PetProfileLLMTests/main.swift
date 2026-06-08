// main.swift
// PetProfileLLMTests 入口
//
// 注册 5 套测试 + 跑全部。
// `swift run PetProfileLLMTests` 跑全部用例。
//
// AppKit 在 SwiftPM 可执行目标里有时需要 setActivationPolicy
//（跟 PetProfileBrain 同款，避免 NSPanel 相关编译问题）。
//

import Foundation
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tests = Tests(suiteName: "PetProfileLLM")

registerKeychainTests(tests)
registerProviderRequestTests(tests)
registerProviderResponseTests(tests)
registerErrorRecoveryTests(tests)
registerIntegrationTests(tests)
// P2-L-1: TextProvider OpenAI stub
registerOpenAITextProviderTests(tests)

let code = tests.run()
exit(code)

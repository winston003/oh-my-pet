// main.swift
// PetProfileBrainTests 入口
//
// 注册 PromptBuilder / MockLLM / Brain 三套测试并跑。
// `swift run PetProfileBrainTests` 跑全部用例。
//

import Foundation
import AppKit
@testable import PetProfileBrain

// AppKit 在 SwiftPM 可执行目标里有时需要 setActivationPolicy
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tests = Tests(suiteName: "PetProfileBrain")

registerPromptBuilderTests(tests)
registerMockLLMTests(tests)
registerBrainTests(tests)

let code = tests.run()
exit(code)

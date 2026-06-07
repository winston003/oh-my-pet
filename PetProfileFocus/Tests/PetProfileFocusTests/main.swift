// main.swift
// PetProfileFocusTests 入口
//
// 注册 4 套测试并跑：`swift run PetProfileFocusTests` 跑全部用例。
//
// 与上游 5 Package 一致：AppKit accessory 模式 + Tests.run() 退出码。
//
import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain
import PetProfileOnboarding
import PetProfileStudio
@testable import PetProfileFocus

// AppKit 在 SwiftPM 可执行目标里需要 setActivationPolicy
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tests = Tests(suiteName: "PetProfileFocus")

registerFocusSessionTests(tests)
registerTaskTrackerTests(tests)
registerSharedMemoryTests(tests)
registerIntegrationTests(tests)

let code = tests.run()
exit(code)
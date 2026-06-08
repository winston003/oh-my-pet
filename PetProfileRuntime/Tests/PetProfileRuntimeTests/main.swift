// main.swift
// PetProfileRuntimeTests 入口
//
// 注册 Loader / PetPanel 两套测试并跑。`swift run PetProfileRuntimeTests` 跑全部。
//
import Foundation
import AppKit
@testable import PetProfileRuntime

// AppKit 在 SwiftPM 可执行目标里有时需要 setActivationPolicy 一下，避免
// 反复运行时候 Window Server 把 stale window 留给我们。accessory = 不进 dock。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let tests = Tests(suiteName: "PetProfileRuntime")

registerLoaderTests(tests)
registerPetPanelTests(tests)
registerSpringAnimationTests(tests)
registerChannelDispatcherTests(tests)
registerActionRouterTests(tests)
// P2-L-2: frontmost app context capture
registerFrontmostAppCaptureTests(tests)

let code = tests.run()
exit(code)

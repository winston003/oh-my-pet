// main.swift
// PetProfileOnboardingApp 命令行入口
//
// 行为：
//   1. 走完 OnboardingFlow 状态机（programmatically，不依赖 GUI 显示）
//   2. 完成后调 PetWindowController 启动 NSPanel
//   3. 打印 stage 转换日志 + NSPanel configuration
//   4. exit 0
//
// 用法：
//   swift run PetProfileOnboardingApp
//   swift run PetProfileOnboardingApp <manifest.json>  # 用指定 manifest 走 D 路径
//
// 不要求 GUI 实际显示；只验证：
//   - 状态机走通（5 阶段 + 跳过逻辑）
//   - OnboardingState 持久化 save/load 正常
//   - NSPanel 创建成功（panel.configurationDescription 可读）
//   - SwiftUI App 入口 build 通过（PetProfileOnboardingApp.main() 编译可用）
//
// Exit code:
//   0 = success
//   1 = failure（state machine 错 / persistence 错 / panel 启动错）
//

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain
import PetProfileOnboarding

// 触发 SwiftUI App 类型检查（不实际启动 GUI）
// 目的：让 swift build 把 SwiftUI 入口编译通过
_ = PetProfileOnboardingApp.self

// AppKit 激活（不显示 UI；只让 NSPanel 创建能跑）
let app = NSApplication.shared
app.setActivationPolicy(.accessory)

func printBanner(_ msg: String) {
    print("[onboarding] \(msg)")
}

// 1. 解析参数（可选 <manifest.json>，无则用 fixture）
let cliManifest: URL? = {
    let args = CommandLine.arguments
    if args.count >= 2 {
        let path = args[1]
        return URL(fileURLWithPath: path)
    }
    return nil
}()

// 2. fresh state（用临时目录避免污染真 ~/Library/Application Support）
let tmpDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("oh-my-pet-onboarding-\(UUID().uuidString.prefix(8))", isDirectory: true)
try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

let stateURL = OnboardingStateStore.url(in: tmpDir)
printBanner("state file: \(stateURL.path)")

// 3. 走流程：welcome → path A → byok → visual → voice → launchPet → completed
var state = OnboardingState()
try state.save(to: stateURL)
printBanner("初始 state saved")

let flow = OnboardingFlow(initialState: state, storeURL: stateURL)

// 选 generate 路径
try flow.choose(path: .generate)
printBanner("→ 选了 .generate 路径；currentStage = \(flow.state.currentStage.displayName)")

// BYOK
try flow.saveByok(provider: "openai", keychainRef: "keychain-ref-mock")
printBanner("→ BYOK 已保存；currentStage = \(flow.state.currentStage.displayName)")

// visual
let profileURL: URL = {
    if let cli = cliManifest {
        return cli
    }
    // 用 PetProfileKit fixture（pako-v1.0.0）当 mock profile URL
    return URL(fileURLWithPath: "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures/pako-v1.0.0.json")
}()
try flow.saveProfile(at: profileURL)
printBanner("→ profile 已保存：\(profileURL.lastPathComponent)")

// voice（style only，不走 clone）
try flow.saveVoice(style: "drawl-deadpan", cloned: false)
printBanner("→ voice style 已保存：\(flow.state.voiceStyle ?? "nil")；voiceCloned=\(flow.state.voiceCloned)")

// launch
try flow.markLaunched()
printBanner("→ launch 已标记；currentStage = \(flow.state.currentStage.displayName)；launchTime = \(flow.state.launchTime?.description ?? "nil")")

// 4. 验证 load roundtrip（字段级比较，launchTime 走 timeIntervalSince1970 Double）
let reloaded = try OnboardingState.load(from: stateURL)
func verifyRoundtrip() -> Bool {
    return reloaded.currentStage == flow.state.currentStage
        && reloaded.chosenPath == flow.state.chosenPath
        && reloaded.petProfilePath == flow.state.petProfilePath
        && reloaded.voiceStyle == flow.state.voiceStyle
        && reloaded.voiceCloned == flow.state.voiceCloned
        && reloaded.voiceCloneConsent == flow.state.voiceCloneConsent
        && reloaded.byokProvider == flow.state.byokProvider
        && reloaded.byokKeychainRef == flow.state.byokKeychainRef
        && reloaded.launchTime != nil
}
guard verifyRoundtrip() else {
    FileHandle.standardError.write(Data("OnboardingState roundtrip 失败：\(reloaded) != \(flow.state)\n".utf8))
    exit(1)
}
printBanner("[OK] OnboardingState roundtrip 通过（字段级）")

// 5. 启动 NSPanel
let controller = PetWindowController()
guard controller.start(with: profileURL) else {
    FileHandle.standardError.write(Data("PetWindowController.start failed\n".utf8))
    exit(1)
}
if let panel = controller.panel {
    printBanner(panel.configurationDescription())
}

printBanner("[OK] PetProfileOnboardingApp: 状态机走通 + NSPanel 启动成功")
exit(0)

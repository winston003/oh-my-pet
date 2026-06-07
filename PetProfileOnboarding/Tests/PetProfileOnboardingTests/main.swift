// main.swift
// PetProfileOnboardingTests 入口：注册全部 test 并运行
//
// `swift run PetProfileOnboardingTests` 跑全部用例。
//
// 注册顺序：
//   - OnboardingState (持久化 + 5 stage 转换 + 错误路径)
//   - OnboardingFlow (4 路径状态机 + 跳过 + 前进/后退)
//   - Stage3Consent (红线校验)
//   - Recovery (损坏文件 → reset)
//
// Exit code:
//   0 = 全部通过
//   1 = 有失败
//

import Foundation
@testable import PetProfileOnboarding

let tests = Tests(suiteName: "PetProfileOnboarding")

registerOnboardingStateTests(tests)
registerOnboardingFlowTests(tests)
registerStage3ConsentTests(tests)
registerRecoveryTests(tests)

let code = tests.run()
exit(code)

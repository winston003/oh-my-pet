// swift-tools-version: 5.9
//
// PetProfileOnboarding — 5 阶段 SwiftUI onboarding + state 持久化 + 集成
// 依赖 PetProfileKit (path: "../PetProfileKit") + PetProfileRuntime (path: "../PetProfileRuntime") + PetProfileBrain (path: "../PetProfileBrain")
//
// 范围 (P2-D)：
//   - OnboardingState Codable + save/load roundtrip
//   - OnboardingFlow state machine（4 路径 + 跳过逻辑 + 失败恢复）
//   - Stage1 / Stage1.5 / Stage2 / Stage3 / Stage4 SwiftUI 屏
//   - Stage 3 voice clone 显式 consent 校验（红线）
//   - PetProfileOnboardingApp 入口：读 state → 走 UI → 调 PetProfileRuntime 显示 NSPanel
//
// 不做：
//   - 不接真 LLM provider（Stage 2 视觉生成用 fixture mock）
//   - 不引入第三方 SwiftUI 库
//   - 不要求 GUI 实际显示（build 成功即可，main 退出 0）
//   - 不写 PetProfileKit / PetProfileRuntime / PetProfileBrain 既有（frozen）
//
// Tests 用自写 TestKit + 独立可执行目标，避开 CommandLineTools 没有
// 公共 XCTest.framework 的问题。`swift run PetProfileOnboardingTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileOnboarding",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfileOnboarding", targets: ["PetProfileOnboarding"]),
        .executable(name: "PetProfileOnboardingApp", targets: ["PetProfileOnboardingApp"]),
        .executable(name: "PetProfileOnboardingTests", targets: ["PetProfileOnboardingTests"])
    ],
    dependencies: [
        .package(path: "../PetProfileKit"),
        .package(path: "../PetProfileRuntime"),
        .package(path: "../PetProfileBrain")
    ],
    targets: [
        .target(
            name: "PetProfileOnboarding",
            dependencies: [
                .product(name: "PetProfile", package: "PetProfileKit"),
                .product(name: "PetProfileRuntime", package: "PetProfileRuntime"),
                .product(name: "PetProfileBrain", package: "PetProfileBrain")
            ],
            path: "Sources/PetProfileOnboarding"
        ),
        .executableTarget(
            name: "PetProfileOnboardingApp",
            dependencies: ["PetProfileOnboarding"],
            path: "Sources/PetProfileOnboardingApp"
        ),
        .executableTarget(
            name: "PetProfileOnboardingTests",
            dependencies: ["PetProfileOnboarding"],
            path: "Tests/PetProfileOnboardingTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

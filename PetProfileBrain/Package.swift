// swift-tools-version: 5.9
//
// PetProfileBrain — AI 大脑层（prompt 编排 + LLM 抽象 + 多通道调度）
// 依赖 PetProfileKit（5 pack + persona schema）+ PetProfileRuntime（loader + ChannelDispatcher）
// 不接真 LLM provider：mock only。BYOK 接入是后续 P2-D 范围。
//
// 范围 (P2-B)：
//   - LLMProvider protocol + MockLLM impl（fixture-based）
//   - PromptBuilder：4 段拼成 system prompt（humor → persona → voice → 5 通道 context）
//   - Brain：拼 prompt → 调 LLM → 解析 → ChannelDispatcher.dispatch(expression:action:audio:)
//   - 单元测试：12-15 fixture 解析 + 12 prompt case + 6 端到端 case
//
// 不做：
//   - 真 LLM provider 接入（BYOK / Keychain / 网络都是 P2-D）
//   - 长期记忆 / 短期会话 context（Pet House 持久化是 P2-C）
//   - 写 PetProfileKit / PetProfileRuntime 既有文件（frozen）
//   - 直接调 NSPanel / SpringAnimation（用 ChannelDispatcher 抽象）
//
// Tests 用自写 TestKit + 独立可执行目标，避开 CommandLineTools 没有
// 公共 XCTest.framework 的问题。`swift run PetProfileBrainTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileBrain",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfileBrain", targets: ["PetProfileBrain"]),
        .executable(name: "PetProfileBrainTests", targets: ["PetProfileBrainTests"])
    ],
    dependencies: [
        .package(path: "../PetProfileKit"),
        .package(path: "../PetProfileRuntime")
    ],
    targets: [
        .target(
            name: "PetProfileBrain",
            dependencies: [
                .product(name: "PetProfile", package: "PetProfileKit"),
                .product(name: "PetProfileRuntime", package: "PetProfileRuntime")
            ],
            path: "Sources/PetProfileBrain"
        ),
        .executableTarget(
            name: "PetProfileBrainTests",
            dependencies: ["PetProfileBrain"],
            path: "Tests/PetProfileBrainTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

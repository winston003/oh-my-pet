// swift-tools-version: 5.9
//
// PetProfileLLM — 真 LLM provider 接入层（OpenAI / Claude / OpenAI-compatible）+ Keychain BYOK
//
// 范围 (P2-G)：
//   - AsyncLLMProvider 协议 + 3 个真 provider impl（HTTP / JSON / URLSession async）
//   - KeychainKeyStore（macOS Security framework，kSecAttrAccessibleWhenUnlockedThisDeviceOnly）
//   - 错误类型 LLMError（5 类）+ 重试策略（network 1 次重试 / 401 不重试 / 429 retry-after / 5xx / timeout 30s）
//   - RealLLMFactory（按 provider name 路由）
//   - 跟 PetProfileBrain 集成：SyncAdapter 把 AsyncLLMProvider 装成 LLMProvider
//     喂给 Brain（Brain.respond 是 sync 的，调用栈无 main-thread 死锁）
//   - main entry：fixture mode 用 MockLLM；BYOK 命中真 keychain 走真 provider
//
// 依赖：
//   - PetProfileKit (path: ../PetProfileKit) — profile schema
//   - PetProfileBrain (path: ../PetProfileBrain) — LLMProvider protocol（sync）+ MockLLM
//   - PetProfileOnboarding (path: ../PetProfileOnboarding) — Stage 1.5 BYOK 字段来源（仅作
//     参考；本 package **不** import 它，因为它是个 iOS-style SwiftUI module；通过 schema
//     string 解析即可）
//
// 不做：
//   - 改 3 个上游 Package 既有（frozen）
//   - 把真 API key 写进 fixture（测试用 mock keychain + URLProtocol mock）
//   - 引入第三方 HTTP 库（Foundation URLSession only）
//   - 在测试里调真 API（URLProtocol mock 拦截）
//   - 缓存 / 持久化 LLM 响应
//   - 语音克隆（属 pet-voice / pet-asset；本 package 只管文本 LLM）
//
// Tests 用自写 TestKit + 独立可执行目标，避开 CommandLineTools 没有
// 公共 XCTest.framework 的问题。`swift run PetProfileLLMTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileLLM",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfileLLM", targets: ["PetProfileLLM"]),
        .executable(name: "PetProfileLLMApp", targets: ["PetProfileLLMApp"]),
        .executable(name: "PetProfileLLMTests", targets: ["PetProfileLLMTests"])
    ],
    dependencies: [
        .package(path: "../PetProfileKit"),
        .package(path: "../PetProfileBrain")
    ],
    targets: [
        .target(
            name: "PetProfileLLM",
            dependencies: [
                .product(name: "PetProfile", package: "PetProfileKit"),
                .product(name: "PetProfileBrain", package: "PetProfileBrain")
            ],
            path: "Sources/PetProfileLLM"
        ),
        .executableTarget(
            name: "PetProfileLLMApp",
            dependencies: ["PetProfileLLM"],
            path: "Sources/PetProfileLLMApp"
        ),
        .executableTarget(
            name: "PetProfileLLMTests",
            dependencies: ["PetProfileLLM"],
            path: "Tests/PetProfileLLMTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

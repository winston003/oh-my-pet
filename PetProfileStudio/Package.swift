// swift-tools-version: 5.9
//
// PetProfileStudio — Pet Studio + Pet House SwiftUI 屏 + PetStore 持久化
// 依赖 PetProfileKit (path: "../PetProfileKit") + PetProfileRuntime (path: "../PetProfileRuntime")
//      + PetProfileOnboarding (path: "../PetProfileOnboarding")
//
// 范围 (P2-E2)：
//   - PetStore：pet 目录 CRUD + 列表加载 + 导出 .omppet
//   - StudioView：Pet 列表 grid（创建 / 编辑 / 删除 + 跳 Pet House）
//   - HouseView：Pet 主页 + 4 tabs（主页 / 记忆 / 贴纸 / 历史）+ export
//   - StudioApp：SwiftUI App 入口（组合 StudioView → HouseView）
//   - PetProfileStudioApp：CLI 入口（`swift run PetProfileStudioApp` 跑 fixture → 启动 app）
//
// 不做：
//   - 改 PetProfileKit / PetProfileRuntime / PetProfileBrain / PetProfileOnboarding 既有（frozen）
//   - 接真 LLM provider（创建 pet 时**只**用 fixture mock；属 P2-G）
//   - 改 AGENTS.md / README.md
//   - 引入第三方 SwiftUI / zip 库（zip 走 /usr/bin/zip）
//   - 实现 NSApp.run() 真实 GUI（不要求 X11 / NSApplication 跑得起来；build 成功即可）
//   - 实现 daily ritual / shared memory 写盘（属 P2-F；本包只读历史数据）
//
// Tests 用自写 TestKit + 独立可执行目标，避开 CommandLineTools 没有
// 公共 XCTest.framework 的问题。`swift run PetProfileStudioTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileStudio",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfileStudio", targets: ["PetProfileStudio"]),
        .executable(name: "PetProfileStudioApp", targets: ["PetProfileStudioApp"]),
        .executable(name: "PetProfileStudioTests", targets: ["PetProfileStudioTests"])
    ],
    dependencies: [
        .package(path: "../PetProfileKit"),
        .package(path: "../PetProfileRuntime"),
        .package(path: "../PetProfileOnboarding"),
        // P2-L-2: SelectionPanel/Coordinator import PetProfileBrain.TextProvider
        //         /TextProviderRegistry / AppContextSnapshot / StubTextProvider /
        //         OpenAITextProvider（type names only, never concrete SDK calls）
        .package(path: "../PetProfileBrain")
    ],
    targets: [
        .target(
            name: "PetProfileStudio",
            dependencies: [
                .product(name: "PetProfile", package: "PetProfileKit"),
                .product(name: "PetProfileRuntime", package: "PetProfileRuntime"),
                .product(name: "PetProfileOnboarding", package: "PetProfileOnboarding"),
                .product(name: "PetProfileBrain", package: "PetProfileBrain")
            ],
            path: "Sources/PetProfileStudio"
        ),
        .executableTarget(
            name: "PetProfileStudioApp",
            dependencies: ["PetProfileStudio"],
            path: "Sources/PetProfileStudioApp"
        ),
        .executableTarget(
            name: "PetProfileStudioTests",
            dependencies: ["PetProfileStudio"],
            path: "Tests/PetProfileStudioTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

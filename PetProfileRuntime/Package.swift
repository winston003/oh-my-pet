// swift-tools-version: 5.9
//
// PetProfileRuntime — PetProfile v1 加载器 + 透明 NSPanel 骨架
// 依赖 PetProfileKit (path: "../PetProfileKit") 做纯数据层 (Codable + 校验)
// AppKit 代码独立放在本 package，保持 PetProfileKit 零 AppKit 依赖
//
// 范围 (P2-A1)：
//   - load v1 manifest + 5 pack + persona → LoadedPetProfile
//   - NSPanel 子类，按 pet-runtime rein agent.md 关键配置
//   - 占位 PNG 生成（不引入真美术资产）
//   - 单元测试：fixture load + NSPanel 配置检查
//
// 不做：事件路由 / 多通道调度 / 3 pet 招牌反应 / Accessibility
//
// Tests 用自写 TestKit + 独立可执行目标，避开 CommandLineTools 没有
// 公共 XCTest.framework 的问题。`swift run PetProfileRuntimeTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileRuntime",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfileRuntime", targets: ["PetProfileRuntime"]),
        .executable(name: "PetProfileRuntimeApp", targets: ["PetProfileRuntimeApp"]),
        .executable(name: "PetProfileRuntimeTests", targets: ["PetProfileRuntimeTests"])
    ],
    dependencies: [
        .package(path: "../PetProfileKit")
    ],
    targets: [
        .target(
            name: "PetProfileRuntime",
            dependencies: [
                .product(name: "PetProfile", package: "PetProfileKit")
            ],
            path: "Sources/PetProfileRuntime"
        ),
        .executableTarget(
            name: "PetProfileRuntimeApp",
            dependencies: ["PetProfileRuntime"],
            path: "Sources/PetProfileRuntimeApp"
        ),
        .executableTarget(
            name: "PetProfileRuntimeTests",
            dependencies: ["PetProfileRuntime"],
            path: "Tests/PetProfileRuntimeTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

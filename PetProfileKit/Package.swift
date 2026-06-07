// swift-tools-version: 5.9
//
// PetProfileKit — PetProfile v1 Swift Codable + 校验 + 升级工具
// 详见 .private/product-design/mvp-pet-schema-draft.md
//
// Tests 用自写 TestKit + 独立可执行目标，避开 CommandLineTools 没有
// 公共 XCTest.framework 的问题。`swift run PetProfileTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileKit",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfile", targets: ["PetProfile"]),
        .executable(name: "PetProfileTests", targets: ["PetProfileTests"])
    ],
    targets: [
        .target(
            name: "PetProfile",
            path: "Sources/PetProfile"
        ),
        .executableTarget(
            name: "PetProfileTests",
            dependencies: ["PetProfile"],
            path: "Tests/PetProfileTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)

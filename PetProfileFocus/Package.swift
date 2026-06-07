// swift-tools-version: 5.9
//
// PetProfileFocus — Focus Session / Task Tracker / Shared Memory 持久化
//
// 依赖（5 上游 Package，全部 frozen，本包只读不改）：
//   - PetProfileKit         (path: ../PetProfileKit)
//   - PetProfileRuntime     (path: ../PetProfileRuntime)
//   - PetProfileBrain       (path: ../PetProfileBrain)
//   - PetProfileOnboarding  (path: ../PetProfileOnboarding)
//   - PetProfileStudio      (path: ../PetProfileStudio)
//
// 范围 (P2-F)：
//   - SharedMemory / MemoryStore：focus + task 完成写盘 + 时间线索引
//   - FocusSession：状态机 (idle/focusing/paused/completed) + 时间统计
//                   + 跟 PetActionRouter 集成 (focusStart/focusEnd/taskDone)
//   - TaskTracker：add / complete / abandon / list (open/completed)
//                  + 跟 FocusSession 联动（complete → 写 memory + taskDone event）
//   - 跟 PetStore 集成：memory 写到 pet 目录的 memories.json（Pet House Tab 读）
//
// 不做：
//   - 改 5 个上游 Package 既有（frozen — mtime 检查）
//   - 引入第三方 state machine / timer 库（用 Foundation Timer + 手写 if/else）
//   - 改 AGENTS.md / README.md
//   - daily ritual 提醒（属 P2-H）
//   - 接真 LLM provider（属 P2-G）
//   - NSApp.run() 真实 GUI（main 跑完流程即 exit 0）
//
// Tests 用自写 TestKit + 独立可执行目标，跟上游 5 Package 一致。
// `swift run PetProfileFocusTests` 跑全部用例。
//
import PackageDescription

let package = Package(
    name: "PetProfileFocus",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "PetProfileFocus", targets: ["PetProfileFocus"]),
        .executable(name: "PetProfileFocusApp", targets: ["PetProfileFocusApp"]),
        .executable(name: "PetProfileFocusTests", targets: ["PetProfileFocusTests"])
    ],
    dependencies: [
        .package(path: "../PetProfileKit"),
        .package(path: "../PetProfileRuntime"),
        .package(path: "../PetProfileBrain"),
        .package(path: "../PetProfileOnboarding"),
        .package(path: "../PetProfileStudio")
    ],
    targets: [
        .target(
            name: "PetProfileFocus",
            dependencies: [
                .product(name: "PetProfile", package: "PetProfileKit"),
                .product(name: "PetProfileRuntime", package: "PetProfileRuntime"),
                .product(name: "PetProfileBrain", package: "PetProfileBrain"),
                .product(name: "PetProfileOnboarding", package: "PetProfileOnboarding"),
                .product(name: "PetProfileStudio", package: "PetProfileStudio")
            ],
            path: "Sources/PetProfileFocus"
        ),
        .executableTarget(
            name: "PetProfileFocusApp",
            dependencies: [
                "PetProfileFocus",
                .product(name: "PetProfile", package: "PetProfileKit"),
                .product(name: "PetProfileRuntime", package: "PetProfileRuntime"),
                .product(name: "PetProfileStudio", package: "PetProfileStudio")
            ],
            path: "Sources/PetProfileFocusApp"
        ),
        .executableTarget(
            name: "PetProfileFocusTests",
            dependencies: ["PetProfileFocus"],
            path: "Tests/PetProfileFocusTests",
            resources: [
                .copy("Fixtures")
            ]
        )
    ]
)
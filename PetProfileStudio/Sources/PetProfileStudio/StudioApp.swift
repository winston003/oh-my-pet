// StudioApp.swift
// PetProfileStudioApp — SwiftUI App 入口
//
// 行为：
//   1. 启动时显示 Pet Studio（Pet 列表 grid）
//   2. 用户点 pet → 切到 Pet House
//   3. Pet House 顶栏有"返回" → 回到 Pet Studio
//   4. "显示桌面" 按钮（可选）→ 启动 NSPanel 把 pet 显示到桌面
//
// 不要求 GUI 实际显示（macOS app 在 SwiftPM executable target 下要 NSApp.run() 才能出窗口；
// 这里用 main 跑完 UI 流程后立即退出；NSPanel show 走 PetWindowController.start）。
//
// @main 在 executable target 的 main.swift 里通过调用
// PetProfileStudioApp.main() 触发；这样 library target 可以独立 import / 测试，
// 不会跟 executable 的 entry point 冲突。
//
// 不做：
//   - 不跑 NSApp.run()（避免 GUI 依赖；后续 P2-G 接）
//   - 不接真 LLM / 不接真 BYOK（mock）
//

import SwiftUI
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileOnboarding
// 注：本文件属于 PetProfileStudio 自身；不显式 import 自己

public struct PetProfileStudioApp: App {
    @StateObject private var studioVM = StudioViewModel()
    @State private var selectedPet: PetSummary?

    public init() {}

    public var body: some Scene {
        WindowGroup("oh-my-pet Studio") {
            NavigationStack {
                if let pet = selectedPet {
                    HouseView(
                        viewModel: HouseViewModel(petID: pet.id),
                        onBack: { selectedPet = nil },
                        onShowDesktopPet: {
                            showDesktopPet(id: pet.id)
                        }
                    )
                } else {
                    StudioView(viewModel: studioVM) { summary in
                        selectedPet = summary
                    }
                }
            }
            .frame(minWidth: 800, minHeight: 600)
        }
    }

    private func showDesktopPet(id: String) {
        let manifest = PetStore.shared.manifestURL(for: id)
        let controller = PetWindowController()
        if !controller.start(with: manifest) {
            FileHandle.standardError.write(Data(
                "PetWindowController.start failed for \(id)\n".utf8
            ))
        }
    }
}

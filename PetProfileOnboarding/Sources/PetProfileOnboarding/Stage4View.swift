// Stage4View.swift
// Stage 4 — 首次 launch 桌面 pet + 引导条
//
// UI 草图（来自 onboarding-flow.md §2 Stage 4）：
//   屏幕中央底部：
//   ┌─────────────────────────────────────────────┐
//   │  [Pako 在你的桌面上]                         │
//   │                                             │
//   │  拖: 移动位置                                │
//   │  戳: 看它反应（试试看）                       │
//   │  右键: 打开菜单（focus / Pet House / ...）    │
//   │                                             │
//   │  [明白了]   [看 30s 演示]                    │
//   └─────────────────────────────────────────────┘
//
// 关键决策：
//   - 引导条**自动消失**（不阻塞用户）
//   - 30s 演示只跑一次（用户点"明白了"或 10s 不动就关）
//   - **不**触发 daily ritual demo（让用户自己发现交互）
//   - 完成这一刻 = 核心里程碑（用户看到 pet 第一次在桌面上动）
//
// 不做：
//   - 不实际启动 NSApp.run()（Stage 4 完成后调 PetWindowController.start 启动 NSPanel）
//   - 不实现 30s 演示的实际动作（属 P2-F 范围）
//   - 不实现 daily ritual（属 P2-F）
//

import SwiftUI
import PetProfile
import PetProfileRuntime

public struct Stage4View: View {

    @ObservedObject var flow: OnboardingFlow
    public var onError: (OnboardingError) -> Void
    public var onFinish: () -> Void
    public var onBack: () -> Void

    @State private var autoDismissTask: Task<Void, Never>? = nil

    public init(
        flow: OnboardingFlow,
        onError: @escaping (OnboardingError) -> Void = { _ in },
        onFinish: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {}
    ) {
        self.flow = flow
        self.onError = onError
        self.onFinish = onFinish
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stage 4 / 4").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)

            Spacer().frame(height: 8)

            VStack(spacing: 8) {
                Text(petName.isEmpty ? "你的 pet 即将出现在桌面上" : "\(petName) 即将出现在桌面上")
                    .font(.largeTitle.weight(.semibold))
                Text("试试拖、戳、右键")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer().frame(height: 24)

            // 占位卡片 —— 模拟 NSPanel
            VStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color(NSColor.controlBackgroundColor))
                        .frame(width: 180, height: 180)
                    Text(petEmoji)
                        .font(.system(size: 90))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HintRow(symbol: "hand.draw", text: "拖: 移动位置")
                    HintRow(symbol: "hand.tap", text: "戳: 看它反应（试试看）")
                    HintRow(symbol: "cursorarrow.click.2", text: "右键: 打开菜单（focus / Pet House / …）")
                }
                .padding(.horizontal, 8)
            }

            Spacer()

            HStack {
                Button("返回") { onBack() }
                Spacer()
                Button("看 30s 演示") {
                    // mock：30s 演示属 P2-F；这里只 log
                }
                .buttonStyle(.bordered)
                Button("明白了") {
                    finish()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 600, minHeight: 540)
    }

    private var petName: String {
        // flow.state.petProfilePath 的最后一段当作名字
        flow.state.petProfilePath?.deletingPathExtension().lastPathComponent ?? ""
    }

    /// 用 petProfilePath 的最后一段字符当 emoji（首字符）
    private var petEmoji: String {
        if let url = flow.state.petProfilePath {
            let name = url.deletingPathExtension().lastPathComponent
            if let first = name.first {
                return String(first).uppercased()
            }
        }
        return "?"
    }

    private func finish() {
        do {
            try flow.markLaunched()
            onFinish()
        } catch {
            onError(error as? OnboardingError ?? .persistenceWriteFailed(reason: error.localizedDescription))
        }
    }
}

struct HintRow: View {
    let symbol: String
    let text: String

    var body: some View {
        H {
            Image(systemName: symbol)
                .frame(width: 20)
                .foregroundColor(.secondary)
            Text(text)
                .font(.callout)
        }
    }
}

// HStack 别名（避免污染全局）
fileprivate typealias H = HStack

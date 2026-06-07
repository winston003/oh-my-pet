// Stage1View.swift
// Stage 1 — 4 路径选择（welcome）
//
// UI 草图（来自 onboarding-flow.md §2 Stage 1）：
//   ┌─────────────────────────────────────────────┐
//   │        欢迎来到 oh-my-pet                   │
//   │                                             │
//   │  你想怎么开始？                              │
//   │  ┌──────┐  ┌──────┐  ┌──────┐  ┌──────┐    │
//   │  │ 🌱  │  │ 🎨  │  │ 📥  │  │ 📦  │    │
//   │  │ 生成 │  │ 上传 │  │ 导入 │  │ 内置 │    │
//   │  └──────┘  └──────┘  └──────┘  └──────┘    │
//   │                                             │
//   │  我们不收数据、不上传、不强制账号。           │
//   └─────────────────────────────────────────────┘
//
// 设计原则（calm / direct / trust-building）：
//   - 4 卡片视觉权重相等（不暗示哪个是"推荐"）
//   - 顶栏"不收数据、不上传、不强制账号"明示
//   - 不用 hype 词
//   - 不用 emoji 替代真图标（emoji 在 macOS 系统字体渲染下跨语言不一致）
//

import SwiftUI

public struct Stage1View: View {

    @ObservedObject var flow: OnboardingFlow
    /// 错误回调（父级 sheet / alert 用）
    public var onError: (OnboardingError) -> Void
    /// 前进到下一 stage 的回调（父级 coordinator 决定怎么切）
    public var onNext: () -> Void

    public init(flow: OnboardingFlow, onError: @escaping (OnboardingError) -> Void = { _ in }, onNext: @escaping () -> Void = {}) {
        self.flow = flow
        self.onError = onError
        self.onNext = onNext
    }

    public var body: some View {
        VStack(spacing: 24) {
            // 顶栏 — trust-building 一句话
            HStack {
                Image(systemName: "lock.shield")
                    .foregroundColor(.secondary)
                Text("不收数据、不上传、不强制账号。")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            Spacer().frame(height: 8)

            // 标题
            VStack(spacing: 8) {
                Text("欢迎来到 oh-my-pet")
                    .font(.largeTitle.weight(.semibold))
                Text("你想怎么开始？")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer().frame(height: 16)

            // 4 路径卡片
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    PathCard(
                        symbol: "sparkles",
                        title: "生成新 pet",
                        subtitle: "AI 文字生成"
                    ) { select(.generate) }
                    PathCard(
                        symbol: "photo.on.rectangle.angled",
                        title: "上传参考图",
                        subtitle: "image-to-image"
                    ) { select(.upload) }
                }
                HStack(spacing: 12) {
                    PathCard(
                        symbol: "tray.and.arrow.down",
                        title: "导入已有",
                        subtitle: ".omppet / .zip"
                    ) { select(.importPath) }
                    PathCard(
                        symbol: "shippingbox",
                        title: "内置 sample",
                        subtitle: "Pako / Mitu / Zorp"
                    ) { select(.sample) }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(minWidth: 520, minHeight: 480)
        .padding(24)
    }

    private func select(_ path: OnboardingPath) {
        do {
            try flow.choose(path: path)
            onNext()
        } catch {
            onError(error as? OnboardingError ?? .invalidStageTransition(from: flow.state.currentStage, to: .welcome))
        }
    }
}

// MARK: - PathCard

struct PathCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 32, weight: .regular))
                    .foregroundColor(.primary)
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }
}

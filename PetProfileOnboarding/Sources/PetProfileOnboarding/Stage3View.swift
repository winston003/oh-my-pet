// Stage3View.swift
// Stage 3 — pet 声音创建
//
// UI 草图（来自 onboarding-flow.md §2 Stage 3）：
//   ┌─────────────────────────────────────────────┐
//   │  给 pet 一个声音                             │
//   │                                             │
//   │  ┌─── 选 voice style ───┐                   │
//   │  │  温柔 / 冷静 / 活泼 / 软绵 / 机械  │  │
//   │  │  低速 / 沙哑                            │  │
//   │  └─────────────────────┘                   │
//   │                                             │
//   │  ── 或 ──                                   │
//   │                                             │
//   │  ┌─── Voice clone（敏感）──┐                 │
//   │  │  [上传样本音频 (.wav/.mp3)]              │  │
//   │  │  ☐ 我拥有这个样本，或有授权使用它        │  │
//   │  │  [生成我的声音]                          │  │
//   │  └──────────────────────────┘               │
//   │                                             │
//   │  [跳过声音，文字回复]   [保存声音]            │
//   └─────────────────────────────────────────────┘
//
// 关键决策（红线 — AGENTS.md "Voice And Consent"）：
//   - **Voice clone 必须显式 consent**：没勾选 userConfirmsOwnership → 拒绝
//   - 样本和生成的 voice profile 都可删除（这是 P2-G 范围）
//   - "跳过"路径：pet 用文字回复，无声音（仍可玩）
//   - 不自动弹试听
//
// 不做：
//   - 不接真 TTS / 不接真 voice clone provider
//   - 不上传样本（UI 上 mock）
//

import SwiftUI

public struct Stage3View: View {

    @ObservedObject var flow: OnboardingFlow
    public var onError: (OnboardingError) -> Void
    public var onNext: () -> Void
    public var onBack: () -> Void

    @State private var selectedStyle: VoiceStylePreset? = .warmGentle
    @State private var sampleFilename: String = ""
    @State private var consentChecked: Bool = false
    @State private var cloneMode: Bool = false

    public enum VoiceStylePreset: String, CaseIterable, Identifiable {
        case warmGentle, calmCool, playfulBright, softFluffy, mechanical, slowLow, husky
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .warmGentle: return "温柔"
            case .calmCool: return "冷静"
            case .playfulBright: return "活泼"
            case .softFluffy: return "软绵"
            case .mechanical: return "机械"
            case .slowLow: return "低速"
            case .husky: return "沙哑"
            }
        }
        /// 跟 PetProfile 5 pet 的 voiceStyle.tone 对齐
        public var tone: String {
            switch self {
            case .warmGentle: return "warm-gentle"
            case .calmCool: return "cold-sarcastic"
            case .playfulBright: return "playful-bright"
            case .softFluffy: return "soft-fluffy"
            case .mechanical: return "electronic-haughty"
            case .slowLow: return "drawl-deadpan"
            case .husky: return "husky-low"
            }
        }
    }

    public init(
        flow: OnboardingFlow,
        onError: @escaping (OnboardingError) -> Void = { _ in },
        onNext: @escaping () -> Void = {},
        onBack: @escaping () -> Void = {}
    ) {
        self.flow = flow
        self.onError = onError
        self.onNext = onNext
        self.onBack = onBack
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Stage 3 / 4").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)

            Spacer().frame(height: 8)

            VStack(spacing: 8) {
                Text("给 pet 一个声音")
                    .font(.largeTitle.weight(.semibold))
            }

            Spacer().frame(height: 16)

            // voice style preset
            VStack(alignment: .leading, spacing: 8) {
                Text("选 voice style")
                    .font(.headline)
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 100), spacing: 8)
                ], spacing: 8) {
                    ForEach(VoiceStylePreset.allCases) { preset in
                        Button(action: {
                            selectedStyle = preset
                            cloneMode = false
                        }) {
                            Text(preset.displayName)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(selectedStyle == preset && !cloneMode
                                              ? Color.accentColor.opacity(0.2)
                                              : Color(NSColor.controlBackgroundColor))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(selectedStyle == preset && !cloneMode
                                                ? Color.accentColor
                                                : Color.secondary.opacity(0.3),
                                                lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 24)

            HStack {
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
                Text("或").font(.caption).foregroundColor(.secondary)
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            // voice clone（敏感）
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                    Text("Voice clone（敏感）")
                        .font(.headline)
                }

                Button(sampleFilename.isEmpty ? "+ 上传样本音频 (.wav/.mp3)" : "已选：\(sampleFilename)") {
                    // mock：填个占位文件名
                    sampleFilename = "user-sample-\(UUID().uuidString.prefix(6)).wav"
                    cloneMode = true
                }
                .buttonStyle(.bordered)
                .disabled(sampleFilename.isEmpty == false)

                Toggle(isOn: $consentChecked) {
                    Text("我拥有这个样本，或有授权使用它")
                        .font(.callout)
                }
                .toggleStyle(.checkbox)
                .disabled(sampleFilename.isEmpty)

                Text("样本和生成的 voice profile 都可删除")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.orange.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1)
            )
            .padding(.horizontal, 24)

            Spacer()

            // 底部
            HStack {
                Button("返回") { onBack() }
                Spacer()
                Button("跳过声音，文字回复") {
                    skip()
                }
                .buttonStyle(.bordered)
                Button("保存声音") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 600, minHeight: 580)
    }

    /// 是否能保存：
    /// - 不走 clone → 选了个 style 即可
    /// - 走 clone → 必须有 sampleFilename + consentChecked
    private var canSave: Bool {
        if cloneMode {
            return !sampleFilename.isEmpty && consentChecked
        }
        return selectedStyle != nil
    }

    private func skip() {
        do {
            try flow.saveVoice(style: nil, cloned: false)
            try flow.next()
            onNext()
        } catch {
            onError(error as? OnboardingError ?? .persistenceWriteFailed(reason: error.localizedDescription))
        }
    }

    private func save() {
        do {
            if cloneMode {
                // 红线：clone 必须有 valid consent
                let consent = VoiceCloneConsent(
                    sampleFilename: sampleFilename,
                    userConfirmsOwnership: consentChecked,
                    consentTimestamp: Date()
                )
                guard consent.isValid else {
                    onError(.consentRequired)
                    return
                }
                try flow.recordVoiceCloneConsent(consent)
                try flow.saveVoice(style: nil, cloned: true)
            } else if let style = selectedStyle {
                try flow.saveVoice(style: style.tone, cloned: false)
            }
            try flow.next()
            onNext()
        } catch let err as OnboardingError {
            onError(err)
        } catch {
            onError(.persistenceWriteFailed(reason: error.localizedDescription))
        }
    }
}

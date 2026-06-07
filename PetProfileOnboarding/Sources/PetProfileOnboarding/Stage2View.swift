// Stage2View.swift
// Stage 2 — pet 视觉创建（A/B 路径）
//
// UI 草图（来自 onboarding-flow.md §2 Stage 2 A 路径）：
//   ┌─────────────────────────────────────────────┐
//   │  描述你的 pet                               │
//   │  Prompt: [安静的云端同伴，帮我写代码___]    │
//   │  风格:   [插画 / 像素 / 卡通 / 2.5D]        │
//   │  色系:   [冷蓝 / 暖橙 / 柔粉 / 黑白]        │
//   │  性格:   [calm] [warm] [playful] [+]        │
//   │  Ref:    [+ 上传参考图（可选）]             │
//   │                                             │
//   │  高级: model / seed / negative prompt [▸]  │
//   │                                             │
//   │  [生成 4 张候选]                             │
//   └─────────────────────────────────────────────┘
//
// 关键决策：
//   - 4 张候选 → 选 1（不批量 8-16 张，避免 cognitive overload）
//   - 选完后自动生成 5 个 state（idle / focus / happy / tired / celebrate）— P2-G 范围
//   - B 路径 = A 路径 + reference image 必填 + slider (参考强度)
//   - 这里**只**用 fixture mock（4 张占位图），不接真 LLM
//
// 不做：
//   - 不接真 LLM
//   - 不实现 5 state 自动生成（P2-G）
//

import SwiftUI

public struct Stage2View: View {

    @ObservedObject var flow: OnboardingFlow
    public var onError: (OnboardingError) -> Void
    public var onNext: () -> Void
    public var onBack: () -> Void

    @State private var prompt: String = ""
    @State private var style: VisualStyle = .illustration
    @State private var color: ColorTone = .coolBlue
    @State private var personalities: Set<String> = ["calm"]
    @State private var referenceImageURL: URL?
    @State private var referenceStrength: Double = 0.5
    @State private var candidates: [CandidateImage] = []
    @State private var selectedCandidate: Int? = nil
    @State private var petName: String = ""
    @State private var isGenerating: Bool = false

    public enum VisualStyle: String, CaseIterable, Identifiable {
        case illustration, pixel, cartoon, twoPoint5D
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .illustration: return "插画"
            case .pixel: return "像素"
            case .cartoon: return "卡通"
            case .twoPoint5D: return "2.5D"
            }
        }
    }

    public enum ColorTone: String, CaseIterable, Identifiable {
        case coolBlue, warmOrange, softPink, blackWhite
        public var id: String { rawValue }
        public var displayName: String {
            switch self {
            case .coolBlue: return "冷蓝"
            case .warmOrange: return "暖橙"
            case .softPink: return "柔粉"
            case .blackWhite: return "黑白"
            }
        }
    }

    public struct CandidateImage: Identifiable, Equatable {
        public let id: Int
        public let label: String
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
            // 顶栏
            HStack {
                Text("Stage 2 / 4").font(.caption).foregroundColor(.secondary)
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, 24)

            Spacer().frame(height: 8)

            VStack(spacing: 8) {
                Text("描述你的 pet")
                    .font(.largeTitle.weight(.semibold))
            }

            if candidates.isEmpty {
                // 表单视图
                formBody
            } else {
                // 候选视图
                candidatesBody
            }

            Spacer()
        }
        .frame(minWidth: 600, minHeight: 540)
        .padding(.bottom, 16)
    }

    // MARK: - form

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Text("Prompt").frame(width: 80, alignment: .trailing)
                TextField("安静的云端同伴，帮我写代码…", text: $prompt, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                Spacer()
            }

            HStack {
                Text("风格").frame(width: 80, alignment: .trailing)
                Picker("", selection: $style) {
                    ForEach(VisualStyle.allCases) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer()
            }

            HStack {
                Text("色系").frame(width: 80, alignment: .trailing)
                Picker("", selection: $color) {
                    ForEach(ColorTone.allCases) { c in
                        Text(c.displayName).tag(c)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
                Spacer()
            }

            HStack(alignment: .top) {
                Text("性格").frame(width: 80, alignment: .trailing)
                HStack {
                    ForEach(["calm", "warm", "playful", "sarcastic"], id: \.self) { tag in
                        Toggle(tag, isOn: Binding(
                            get: { personalities.contains(tag) },
                            set: { on in
                                if on { personalities.insert(tag) } else { personalities.remove(tag) }
                            }
                        ))
                        .toggleStyle(.button)
                    }
                }
                Spacer()
            }

            if flow.state.chosenPath == .upload {
                HStack(alignment: .top) {
                    Text("Ref").frame(width: 80, alignment: .trailing)
                    VStack(alignment: .leading) {
                        Button(referenceImageURL == nil ? "+ 上传参考图" : "已选：\(referenceImageURL!.lastPathComponent)") {
                            // mock：选第一个 fixture
                            referenceImageURL = URL(fileURLWithPath: "/tmp/ref.png")
                        }
                        .buttonStyle(.bordered)
                        if referenceImageURL != nil {
                            HStack {
                                Text("参考强度")
                                Slider(value: $referenceStrength, in: 0...1)
                                Text(String(format: "%.0f%%", referenceStrength * 100))
                                    .frame(width: 40, alignment: .trailing)
                            }
                        }
                    }
                    Spacer()
                }
            }

            Spacer().frame(height: 8)

            HStack {
                Button("返回") { onBack() }
                Spacer()
                Button(isGenerating ? "生成中…" : "生成 4 张候选") {
                    generateCandidates()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(prompt.isEmpty || isGenerating)
            }
            .padding(.horizontal, 24)
        }
        .padding(24)
    }

    // MARK: - candidates

    private var candidatesBody: some View {
        VStack(spacing: 16) {
            Text("选你最喜欢的一张")
                .font(.title3)

            HStack(spacing: 12) {
                ForEach(candidates) { c in
                    Button(action: { selectedCandidate = c.id }) {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(NSColor.controlBackgroundColor))
                                    .frame(width: 110, height: 110)
                                Text(c.label)
                                    .font(.system(size: 36, weight: .bold))
                                    .foregroundColor(.secondary)
                                if selectedCandidate == c.id {
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 3)
                                        .frame(width: 110, height: 110)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("名字").frame(width: 60, alignment: .trailing)
                TextField("Mochi", text: $petName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
            }
            .padding(.horizontal, 24)

            HStack {
                Button("重新生成 4 张") {
                    generateCandidates()
                }
                Spacer()
                Button("选这 1 张继续") {
                    saveAndNext()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(selectedCandidate == nil || petName.isEmpty)
            }
            .padding(.horizontal, 24)
        }
        .padding(24)
    }

    // MARK: - actions

    private func generateCandidates() {
        isGenerating = true
        // mock: 4 张占位
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            isGenerating = false
            candidates = (1...4).map { CandidateImage(id: $0, label: "\(petName.isEmpty ? "?" : petName.prefix(1))\($0)") }
            selectedCandidate = nil
        }
    }

    private func saveAndNext() {
        // mock 存个 URL（生产环境会调真 LLM 生成 + 写盘）
        let mockURL = URL(fileURLWithPath: "/tmp/\(petName).omppet/manifest.json")
        do {
            try flow.saveProfile(at: mockURL)
            try flow.next()
            onNext()
        } catch {
            onError(error as? OnboardingError ?? .persistenceWriteFailed(reason: error.localizedDescription))
        }
    }
}

// SelectionPanel.swift
// SelectionPanel — SwiftUI sheet 显示 send-confirm UI
//
// 责任（spec §3.1 "每次调用前 UI 必须展示：provider id、model、数据类型、发送内容预览"）：
//   - 顶部固定行：`Provider: {id} · Model: {modelUsed} · Type: text completion`
//   - 中部 selectedText preview（最多 5 行，可滚动，**不**截断 80 字符）
//   - 旁边 AppContext 小卡（appName · bundleID · capturedAt 相对时间）
//   - 5 个 action 按钮：Translate / Explain / Summarize / Rewrite / Ask Freeform
//   - 底部 [Cancel] [Send]
//   - 收到 result 后下方显示（可滚动），[Close]
//   - [Send] 后按钮 disabled + ProgressView
//
// 设计要点：
//   - SwiftUI View（@MainActor）
//   - 依赖 SelectionCoordinator（ObservableObject；View 观察 phase 变化）
//   - 5 个 action 按钮：默认 explain 高亮（与 coordinator 默认一致）
//   - provider dropdown 列出 TextProviderRegistry.shared.allProviders
//     - requiresAPIKey == true 的显示 🔑 标记
//     - 改变 dropdown → 调 coordinator.selectProvider(id:)
//   - 固定行不变量（spec §3.1）：顶部行**始终**显示（即使 result 出现后仍显示，
//     让用户看得到"这是哪个 provider / model / 什么 data type")
//   - "相对时间"用 Date.RelativeFormatStyle（iOS 15+ / macOS 12+）
//
// 不做：
//   - 不写 network call（coordinator.send 调 provider）
//   - 不实现 streaming（spec §3.1 单次 result；不暴露 partial progress）
//   - 不写盘（result 仅 in-memory；P2-N 加 SelectionResultCache）
//   - 不自动清剪贴板
//
// 测试：
//   - SelectionPanelTests 用 Snapshot test / View introspection 覆盖（见 P2-E2 模式）
//   - 5 个 action 按钮都 enabled（默认不选则 explain 高亮，其他也 enabled）
//   - provider dropdown 包含 TextProviderRegistry.allProviders 全部

import SwiftUI
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain

// MARK: - SelectionPanel

public struct SelectionPanel: View {

    @ObservedObject var coordinator: SelectionCoordinator
    @State private var isShowing = true

    public init(coordinator: SelectionCoordinator) {
        self.coordinator = coordinator
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 顶部固定行：Provider · Model · Type（spec §3.1 不变量）
            if let inv = headerInvariant {
                HStack(spacing: 6) {
                    Text("Provider: \(inv.providerID)").font(.system(.body, design: .monospaced))
                    Text("·").foregroundStyle(.secondary)
                    Text("Model: \(inv.model)").font(.system(.body, design: .monospaced))
                    Text("·").foregroundStyle(.secondary)
                    Text("Type: text completion").font(.system(.body, design: .monospaced))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            // 不同 phase 不同 layout
            switch coordinator.phase {
            case .idle, .dismissed:
                EmptyView()

            case .info(let message):
                infoView(message: message)

            case .readyForUser(let state):
                userInputView(state: state)

            case .running(let state):
                runningView(state: state)

            case .completed(let state, let result):
                userInputView(state: state, inputDisabled: true)
                resultView(result: result)

            case .failed(let state, let errorMessage):
                userInputView(state: state, inputDisabled: true)
                errorView(message: errorMessage)
            }
        }
        .padding(16)
        .frame(minWidth: 520, minHeight: 360)
    }

    // MARK: - Header invariant

    /// "Provider: X · Model: Y · Type: Z" 顶部固定行；不依赖 phase 是哪个。
    /// idle / dismissed / info 阶段不显示（没有具体 provider/model）。
    private var headerInvariant: (providerID: String, model: String)? {
        switch coordinator.phase {
        case .readyForUser(let s), .running(let s):
            return (s.providerID, s.model)
        case .completed(let s, _), .failed(let s, _):
            return (s.providerID, s.model)
        case .idle, .dismissed, .info:
            return nil
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func infoView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(message)
                .font(.body)
                .padding()
                .background(Color.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Close") {
                    coordinator.clearInfo()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    @ViewBuilder
    private func userInputView(state: SelectionState, inputDisabled: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider dropdown
            providerDropdown(state: state, disabled: inputDisabled)

            // Selected text preview (5 行，可滚动，**不**截断)
            VStack(alignment: .leading, spacing: 4) {
                Text("Selected text").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(state.selectedText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 5 * 18)  // ~5 lines
                .padding(8)
                .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            }

            // AppContext 小卡
            appContextCard(appContext: state.appContext)

            // 5 个 action 按钮
            actionButtons(state: state, disabled: inputDisabled)

            // 底部 [Cancel] [Send]
            HStack {
                Spacer()
                Button("Cancel") {
                    coordinator.cancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(inputDisabled)

                Button("Send") {
                    coordinator.send()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(inputDisabled)
            }
        }
    }

    @ViewBuilder
    private func runningView(state: SelectionState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            userInputView(state: state, inputDisabled: true)
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Calling \(state.providerID) (\(state.action.rawValue))…")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func resultView(result: TextCompletionResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Result").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text("latency \(result.latencyMS) ms").font(.caption2).foregroundStyle(.tertiary)
            }
            ScrollView {
                Text(result.text)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 200)
            .padding(8)
            .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))

            HStack {
                Spacer()
                Button("Close") {
                    coordinator.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Error").font(.caption).foregroundStyle(.red)
            Text(message)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
            HStack {
                Spacer()
                Button("Close") {
                    coordinator.close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func providerDropdown(state: SelectionState, disabled: Bool) -> some View {
        let providers = coordinator.allProvidersList
        HStack(spacing: 8) {
            Text("Provider:").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(
                get: { state.providerID },
                set: { newID in
                    coordinator.selectProvider(id: newID)
                }
            )) {
                ForEach(providers, id: \.id) { p in
                    HStack {
                        if p.requiresAPIKey {
                            Text("\(p.displayName) 🔑")
                        } else {
                            Text(p.displayName)
                        }
                    }
                    .tag(p.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(disabled)
        }
    }

    @ViewBuilder
    private func appContextCard(appContext: AppContextSnapshot) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appContext.appName).font(.subheadline).bold()
                if let bid = appContext.bundleID {
                    Text(bid).font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text("(no bundle id)").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("captured \(relativeTime(appContext.capturedAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // windowTitle 永远 nil（spec §1 P5 不读）
                if appContext.windowTitle != nil {
                    Text(appContext.windowTitle ?? "")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("(no window title — MVP)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func actionButtons(state: SelectionState, disabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Action").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(SelectionActionKind.allCases, id: \.self) { kind in
                    Button {
                        coordinator.selectAction(kind)
                    } label: {
                        Text(actionLabel(kind))
                            .frame(minWidth: 70)
                    }
                    .disabled(disabled)
                    .buttonStyle(.bordered)
                    .background(
                        state.action == kind
                        ? Color.accentColor.opacity(0.18)
                        : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }

    // MARK: - Helpers

    private func actionLabel(_ kind: SelectionActionKind) -> String {
        switch kind {
        case .translate: return "Translate"
        case .explain: return "Explain"
        case .summarize: return "Summarize"
        case .rewrite: return "Rewrite"
        case .ask: return "Ask Freeform"
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Coordinator.allProviders() 暴露（View 端用）
//
// 已通过 SelectionCoordinator.allProvidersList 暴露。Extension 留作占位，
// 未来想加 view-only helpers（例如 isProviderAvailable）时可放这里。
extension SelectionCoordinator {}

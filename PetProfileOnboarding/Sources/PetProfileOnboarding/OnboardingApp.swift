// OnboardingApp.swift
// PetProfileOnboardingApp — SwiftUI App 入口
//
// 行为：
//   1. 启动时读 OnboardingState（不存在 → fresh；损坏 → reset + fresh）
//   2. 决定从哪个 stage 开始（继续未完成的 / 重新走）
//   3. 跑 5 阶段 SwiftUI 屏
//   4. 完成后调 PetWindowController 把 NSPanel show 出来
//   5. exit 0
//
// 不要求 GUI 实际显示（macOS app 在 SwiftPM executable target 下要 NSApp.run() 才能出窗口；
// 这里用 main 跑完 UI 流程后立即退出；NSPanel show 走 PetWindowController.start）。
//
// Exit code:
//   0 = success（onboarding 完成或重新开始）
//   1 = 启动失败（state 加载/重置失败 + pet profile load 失败）
//
// 不做：
//   - 不跑 NSApp.run()（避免 GUI 依赖；P2-E 才会接）
//   - 不做真 BYOK / 真 TTS（mock）
//
// 注意：这里**没有** @main。@main 在 executable target 的 main.swift 里通过调用
// PetProfileOnboardingApp.main() 触发；这样 library target 可以独立 import / 测试，
// 不会跟 executable 的 entry point 冲突。
//

import SwiftUI
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileBrain

public struct PetProfileOnboardingApp: App {

    @StateObject private var flow: OnboardingFlow

    public init() {
        // 1. 读 OnboardingState（损坏 → reset；不存在 → fresh）
        let initial = Self.loadOrResetInitialState()
        _flow = StateObject(wrappedValue: OnboardingFlow(initialState: initial))
    }

    public var body: some Scene {
        WindowGroup("oh-my-pet onboarding") {
            OnboardingRootView(flow: flow)
        }
    }

    // MARK: - 启动状态恢复

    private static func loadOrResetInitialState() -> OnboardingState {
        do {
            return try OnboardingState.load()
        } catch OnboardingError.stateFileNotFound {
            return OnboardingState()
        } catch OnboardingError.stateFileCorrupted {
            // 失败恢复：损坏 → reset → 从 Stage 1 开始
            do {
                return try OnboardingState.reset()
            } catch {
                FileHandle.standardError.write(Data(
                    "OnboardingState.reset failed after corrupted load: \(error)\n".utf8
                ))
                return OnboardingState()
            }
        } catch {
            FileHandle.standardError.write(Data(
                "OnboardingState.load failed: \(error)\n".utf8
            ))
            return OnboardingState()
        }
    }
}

// MARK: - OnboardingRootView

/// Coordinator view：按 flow.state.currentStage 切到对应 Stage 屏
public struct OnboardingRootView: View {
    @ObservedObject var flow: OnboardingFlow
    @State private var errorMessage: String? = nil

    public init(flow: OnboardingFlow) {
        self.flow = flow
    }

    public var body: some View {
        Group {
            switch flow.state.currentStage {
            case .welcome:
                Stage1View(
                    flow: flow,
                    onError: handle(error:),
                    onNext: { /* @Published state 触发重渲染 */ }
                )
            case .byokSetup:
                Stage1_5View(
                    flow: flow,
                    onError: handle(error:),
                    onNext: {},
                    onBack: { back() }
                )
            case .visualCreate:
                Stage2View(
                    flow: flow,
                    onError: handle(error:),
                    onNext: {},
                    onBack: { back() }
                )
            case .voiceCreate:
                Stage3View(
                    flow: flow,
                    onError: handle(error:),
                    onNext: {},
                    onBack: { back() }
                )
            case .launchPet:
                Stage4View(
                    flow: flow,
                    onError: handle(error:),
                    onFinish: { finish() },
                    onBack: { back() }
                )
            case .completed:
                CompletionView(flow: flow)
            }
        }
        .alert("出错", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func handle(error: OnboardingError) {
        errorMessage = error.description
    }

    private func back() {
        do {
            try flow.back()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finish() {
        // Stage 4 完成 → markLaunched → state == .completed → CompletionView 出现
        // CompletionView 自己负责调 PetWindowController 启动 NSPanel
    }
}

// MARK: - CompletionView

struct CompletionView: View {
    @ObservedObject var flow: OnboardingFlow
    @State private var panelStatus: String = "准备启动桌面 pet…"

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundColor(.green)
            Text("完成")
                .font(.largeTitle.weight(.semibold))
            Text("pet 已经准备好出现在你的桌面上了。")
                .font(.body)
                .foregroundColor(.secondary)
            Text(panelStatus)
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 8)

            Button("启动 pet") {
                launchPanel()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 360)
        .onAppear {
            launchPanel()
        }
    }

    private func launchPanel() {
        guard let profileURL = flow.state.petProfilePath else {
            // 没 profile path → 用 fixture 兜底
            panelStatus = "（无 profile URL；只 build 不要求 GUI 实际显示）"
            return
        }
        let controller = PetWindowController()
        if controller.start(with: profileURL) {
            if let panel = controller.panel {
                panelStatus = "NSPanel 已启动：\(panel.profile.manifest.name)（id=\(panel.profile.manifest.id.raw)）"
            } else {
                panelStatus = "PetWindowController 启动成功（panel 已显示）"
            }
        } else {
            panelStatus = "PetWindowController.start 失败（可降级为纯 SwiftUI）"
        }
    }
}

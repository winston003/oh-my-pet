// Stage1_5View.swift
// Stage 1.5 — BYOK 配置（仅 A/B 路径）
//
// UI 草图（来自 onboarding-flow.md §2 Stage 1.5）：
//   ┌─────────────────────────────────────────────┐
//   │  设置 AI Provider                           │
//   │                                             │
//   │  你需要自带一个 AI provider key。            │
//   │  我们存在 macOS Keychain，不上传。            │
//   │                                             │
//   │  Provider: [OpenAI ▼]                       │
//   │  API Key:   [____________________]  [Test] │
//   │                                             │
//   │  [跳过，用 default provider]   [保存并继续] │
//   │                                             │
//   │  没有 key？[申请 OpenAI key →]               │
//   └─────────────────────────────────────────────┘
//
// 关键决策：
//   - "Test" 按钮跑一次小请求验证 key 有效（这里只 mock；真 BYOK 是 P2-D 后续范围）
//   - "跳过" 用 default provider（不羞辱 — 顶栏明示「功能受限」也行）
//   - API key 走 Keychain 引用（不存任何文件）
//   - C/D 路径**不会**进入这屏（OnboardingFlow.choose(path:) 直接跳过）
//
// 不做：
//   - 不接真 LLM（"Test" 只校验 key 长度非空）
//   - 不实际写 Keychain（用 mock keychain ref 字符串）
//

import SwiftUI

public struct Stage1_5View: View {

    @ObservedObject var flow: OnboardingFlow
    public var onError: (OnboardingError) -> Void
    public var onNext: () -> Void
    public var onBack: () -> Void

    @State private var provider: String = "openai"
    @State private var apiKey: String = ""
    @State private var testResult: TestResult = .none
    @State private var isTesting: Bool = false

    public enum TestResult: Equatable {
        case none
        case success
        case failure(String)
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
        VStack(spacing: 20) {
            // 顶栏 — trust-building
            HStack {
                Image(systemName: "key.fill")
                    .foregroundColor(.secondary)
                Text("我们存在 macOS Keychain，不上传。")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)

            Spacer().frame(height: 8)

            VStack(spacing: 8) {
                Text("设置 AI Provider")
                    .font(.largeTitle.weight(.semibold))
                Text("你需要自带一个 AI provider key。")
                    .font(.title3)
                    .foregroundColor(.secondary)
            }

            Spacer().frame(height: 16)

            // 表单
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Provider")
                        .frame(width: 80, alignment: .trailing)
                    Picker("", selection: $provider) {
                        Text("OpenAI").tag("openai")
                        Text("Anthropic").tag("anthropic")
                        Text("Custom").tag("custom")
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    Spacer()
                }

                HStack {
                    Text("API Key")
                        .frame(width: 80, alignment: .trailing)
                    SecureField("sk-...", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 280)
                    Button(action: testKey) {
                        if isTesting {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 50)
                        } else {
                            Text("Test")
                                .frame(width: 50)
                        }
                    }
                    .disabled(apiKey.isEmpty || isTesting)
                    Spacer()
                }

                // Test 结果
                switch testResult {
                case .none:
                    EmptyView()
                case .success:
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                        Text("key 有效").font(.callout).foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.leading, 96)
                case .failure(let msg):
                    HStack {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                        Text(msg).font(.callout).foregroundColor(.red)
                        Spacer()
                    }
                    .padding(.leading, 96)
                }
            }
            .padding(.horizontal, 24)

            Spacer()

            // 底部按钮
            HStack {
                Button("返回") {
                    onBack()
                }
                Spacer()
                Button("跳过，用 default provider") {
                    save(provider: "default", keychainRef: nil)
                }
                .buttonStyle(.bordered)
                Button("保存并继续") {
                    save(provider: provider, keychainRef: "keychain-ref-\(UUID().uuidString.prefix(8))")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(apiKey.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 560, minHeight: 460)
        .padding(24)
    }

    private func testKey() {
        isTesting = true
        testResult = .none
        // mock 校验：长度 >= 8 视为 ok；这是 Stage 1.5 的 UI demo，不是真 BYOK
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            isTesting = false
            if apiKey.count >= 8 {
                testResult = .success
            } else {
                testResult = .failure("key 太短（至少 8 字符）")
            }
        }
    }

    private func save(provider: String, keychainRef: String?) {
        do {
            try flow.saveByok(provider: provider, keychainRef: keychainRef)
            onNext()
        } catch {
            onError(error as? OnboardingError ?? .persistenceWriteFailed(reason: error.localizedDescription))
        }
    }
}

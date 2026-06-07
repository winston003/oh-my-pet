// StudioView.swift
// StudioView — Pet 列表（grid）+ 创建 / 编辑 / 删除 + 跳 Pet House
//
// UI（来自任务描述）：
//   - Grid layout，3 列
//   - 每张卡：pet 缩略图（idle state）+ 名字 + 性格 tags
//   - 点击 → 跳到 Pet House
//   - 右上角 + 按钮 → 创建新 pet
//
// 创建流程（"复用 PetProfileOnboarding Stage 2 视觉创建"）：
//   - Studio 不要求重跑 Stage 2 的全部表单（prompt / style / 4 张候选）。
//   - 简化版：从 fixture 复制（pako / mitu / zorp 任一）做基础，
//     用户改 name + personality tags 即可。这样不动 PetProfileOnboarding 既有。
//   - 注：完整 AI 生成走 Stage 2；本屏只做"基于 sample 的快速编辑"。
//
// 编辑流程：
//   - 改 name
//   - 改 personality tags（PersonaCard.backstoryTags）
//   - 改 voice style（AudioPack.voiceStyle.tone）
//   - 重新生成 state image — 本版本用占位（runtime.Loader 已有 ensurePlaceholderImage，
//     编辑屏不动 PNG，只更新 manifest 字段；后续 P2-G 可接真生成）
//
// 删除流程：
//   - 弹 SwiftUI confirmationDialog
//   - 二次确认 → PetStore.delete()
//
// 不做：
//   - 不接真 LLM（创建用 fixture mock）
//   - 不实现 drag-and-drop pet 排序
//   - 不实现搜索 / 过滤（3-5 只 pet 不需要）
//

import SwiftUI
import PetProfile
import PetProfileRuntime
import PetProfileOnboarding

// MARK: - StudioViewModel

// 不加 @MainActor —— 跟 OnboardingFlow 同样的 pattern，避免 View.init 默认参数的 actor 隔离报错。
// @Published / ObservableObject 的 thread safety 由 SwiftUI runtime 处理。
public final class StudioViewModel: ObservableObject {
    @Published public var summaries: [PetSummary] = []
    @Published public var error: String?
    @Published public var isLoading: Bool = false

    /// 当前编辑 / 创建的表单状态
    @Published public var draft: PetDraft = PetDraft()
    @Published public var editorMode: EditorMode = .none

    public enum EditorMode: Equatable {
        case none
        case create
        case edit(originalID: String)
    }

    /// PetStore — 注入用（默认 = .shared）
    public let store: PetStore

    /// PetProfileOnboarding 的"sample"路径：可用的默认 pet（pako/mitu/zorp）
    public let availableSamples: [SamplePet]

    public init(
        store: PetStore = .shared,
        availableSamples: [SamplePet] = SamplePet.builtInSamples
    ) {
        self.store = store
        self.availableSamples = availableSamples
    }

    // MARK: - 加载

    public func reload() {
        isLoading = true
        defer { isLoading = false }
        do {
            summaries = try store.loadAll()
            error = nil
        } catch {
            self.error = "加载 pet 列表失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 创建

    /// 从 sample fixture 创建新 pet
    public func createFromSample(_ sample: SamplePet) {
        do {
            // 1. 复制 sample 目录到 pet store（用 sample.profileRoot 源）
            let loaded = try PetProfileLoader().loadProfile(from: sample.manifestURL)
            try store.create(profile: loaded)
            error = nil
            reload()
        } catch {
            self.error = "创建 pet 失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 编辑

    public func beginEdit(_ summary: PetSummary) {
        do {
            let loaded = try store.load(id: summary.id)
            draft = PetDraft.from(loaded: loaded)
            editorMode = .edit(originalID: summary.id)
        } catch {
            self.error = "读取 pet 失败：\(error.localizedDescription)"
        }
    }

    public func beginCreate() {
        draft = PetDraft()
        editorMode = .create
    }

    public func cancelEditor() {
        editorMode = .none
        draft = PetDraft()
    }

    public func commitEditor() {
        switch editorMode {
        case .none:
            return
        case .create:
            // 创建：用 draft.fromSample 作为基础（默认 Pako） + 应用 draft 覆盖
            let sample = availableSamples.first(where: { $0.id == draft.sampleID })
                ?? availableSamples.first
            guard let sample = sample else {
                error = "没有可用的 sample pet"
                return
            }
            do {
                let loaded = try PetProfileLoader().loadProfile(from: sample.manifestURL)
                var manifest = loaded.manifest
                manifest = draft.apply(to: manifest)
                let updated = LoadedPetProfile(
                    profileRoot: loaded.profileRoot,
                    manifest: manifest,
                    visualAssetURLs: loaded.visualAssetURLs,
                    expressionAssetURLs: loaded.expressionAssetURLs,
                    actionIdleAssetURL: loaded.actionIdleAssetURL,
                    actionReactionAssetURLs: loaded.actionReactionAssetURLs,
                    voiceCloneSampleURL: loaded.voiceCloneSampleURL
                )
                try store.create(profile: updated)
                editorMode = .none
                draft = PetDraft()
                reload()
            } catch {
                self.error = "创建 pet 失败：\(error.localizedDescription)"
            }
        case .edit(let id):
            do {
                let loaded = try store.load(id: id)
                var manifest = loaded.manifest
                manifest = draft.apply(to: manifest)
                let updated = LoadedPetProfile(
                    profileRoot: loaded.profileRoot,
                    manifest: manifest,
                    visualAssetURLs: loaded.visualAssetURLs,
                    expressionAssetURLs: loaded.expressionAssetURLs,
                    actionIdleAssetURL: loaded.actionIdleAssetURL,
                    actionReactionAssetURLs: loaded.actionReactionAssetURLs,
                    voiceCloneSampleURL: loaded.voiceCloneSampleURL
                )
                try store.update(updated)
                editorMode = .none
                draft = PetDraft()
                reload()
            } catch {
                self.error = "更新 pet 失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - 删除

    public func delete(_ summary: PetSummary) {
        do {
            try store.delete(id: summary.id)
            reload()
        } catch {
            self.error = "删除 pet 失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - PetDraft

/// 编辑 / 创建表单的 in-memory draft — 包含 name + voice style + personality tags
public struct PetDraft: Equatable {
    public var name: String = ""
    public var sampleID: String = "pako"
    public var personalityTags: [String] = []
    public var voiceTone: String = "neutral"

    public init() {}

    public init(name: String, sampleID: String, personalityTags: [String], voiceTone: String) {
        self.name = name
        self.sampleID = sampleID
        self.personalityTags = personalityTags
        self.voiceTone = voiceTone
    }

    public static func from(loaded: LoadedPetProfile) -> PetDraft {
        let m = loaded.manifest
        return PetDraft(
            name: m.name,
            sampleID: m.id.raw,  // 编辑现有 = 保持原 id
            personalityTags: m.persona.backstoryTags ?? [],
            voiceTone: m.audio.voiceStyle.tone
        )
    }

    /// 应用 draft 覆盖到 manifest
    public func apply(to manifest: PetProfileV1) -> PetProfileV1 {
        // 注意：PetProfileV1 是 let 结构，需要 rebuild
        // 用 init(...) 重建
        let newName = name.isEmpty ? manifest.name : name
        let newPersona = PersonaCard(
            name: manifest.persona.name,
            loreShort: manifest.persona.loreShort,
            loreFull: manifest.persona.loreFull,
            relationshipWithUser: manifest.persona.relationshipWithUser,
            recurringMotifs: manifest.persona.recurringMotifs,
            backstoryTags: personalityTags.isEmpty ? nil : personalityTags
        )
        let newVoiceStyle = VoiceStyle(
            pitch: manifest.audio.voiceStyle.pitch,
            speed: manifest.audio.voiceStyle.speed,
            energy: manifest.audio.voiceStyle.energy,
            tone: voiceTone
        )
        let newAudio = AudioPack(
            ttsProvider: manifest.audio.ttsProvider,
            ttsVoice: manifest.audio.ttsVoice,
            voiceStyle: newVoiceStyle,
            catchphrases: manifest.audio.catchphrases,
            voiceCloneConsent: manifest.audio.voiceCloneConsent
        )
        return PetProfileV1(
            version: manifest.version,
            minRuntimeVersion: manifest.minRuntimeVersion,
            id: manifest.id,
            name: newName,
            createdAt: manifest.createdAt,
            locale: manifest.locale,
            visual: manifest.visual,
            audio: newAudio,
            action: manifest.action,
            expression: manifest.expression,
            humor: manifest.humor,
            persona: newPersona
        )
    }
}

// MARK: - SamplePet

/// 默认 sample pet — 指向 PetProfileKit fixture 的 manifest URL
public struct SamplePet: Equatable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let manifestURL: URL

    public init(id: String, displayName: String, manifestURL: URL) {
        self.id = id
        self.displayName = displayName
        self.manifestURL = manifestURL
    }

    /// 3 个 default pet（pako/mitu/zorp v1 fixture）
    /// 路径相对 PetProfileKit/Tests/PetProfileTests/Fixtures/
    public static let builtInSamples: [SamplePet] = {
        // 走 env 变量或默认 repo 路径
        // 优先 STUDIO_FIXTURE_ROOT，其次 PETPROFILEKIT_FIXTURE_ROOT，最后 hardcode
        let env = ProcessInfo.processInfo.environment
        let base = env["STUDIO_FIXTURE_ROOT"]
            ?? env["PETPROFILEKIT_FIXTURE_ROOT"]
            ?? "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
        return [
            SamplePet(
                id: "pako",
                displayName: "Pako（果冻）",
                manifestURL: URL(fileURLWithPath: "\(base)/pako-v1.0.0.json")
            ),
            SamplePet(
                id: "mitu",
                displayName: "Mitu（多毛）",
                manifestURL: URL(fileURLWithPath: "\(base)/mitu-v1.0.0.json")
            ),
            SamplePet(
                id: "zorp",
                displayName: "Zorp（外星）",
                manifestURL: URL(fileURLWithPath: "\(base)/zorp-v1.0.0.json")
            ),
        ]
    }()
}

// MARK: - StudioView

public struct StudioView: View {
    @StateObject public var viewModel: StudioViewModel
    @State public var onSelectPet: (PetSummary) -> Void

    /// 三列 grid — 用 LazyVGrid
    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 16),
        count: 3
    )

    public init(
        viewModel: StudioViewModel = StudioViewModel(),
        onSelectPet: @escaping (PetSummary) -> Void = { _ in }
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onSelectPet = onSelectPet
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .onAppear {
                if viewModel.summaries.isEmpty {
                    viewModel.reload()
                }
            }
            .alert("出错", isPresented: Binding(
                get: { viewModel.error != nil },
                set: { if !$0 { viewModel.error = nil } }
            )) {
                Button("OK") { viewModel.error = nil }
            } message: {
                Text(viewModel.error ?? "")
            }
            .sheet(isPresented: Binding(
                get: { viewModel.editorMode != .none },
                set: { if !$0 { viewModel.cancelEditor() } }
            )) {
                PetEditorView(viewModel: viewModel)
            }
        }
    }

    // MARK: - header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pet Studio")
                    .font(.largeTitle.weight(.semibold))
                Text("管理你的桌面伙伴")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                viewModel.beginCreate()
            } label: {
                Label("新建 pet", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        if viewModel.summaries.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(viewModel.summaries) { summary in
                        PetCardView(summary: summary) {
                            onSelectPet(summary)
                        } onEdit: {
                            viewModel.beginEdit(summary)
                        } onDelete: {
                            viewModel.delete(summary)
                        }
                    }
                }
                .padding(24)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "pawprint.circle")
                .font(.system(size: 64))
                .foregroundColor(.secondary)
            Text("还没有 pet")
                .font(.title2)
            Text("点击右上角「新建 pet」开始")
                .font(.body)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - PetCardView

struct PetCardView: View {
    let summary: PetSummary
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 缩略图（idle state）
            thumbnail
            // 名字
            Text(summary.name)
                .font(.headline)
                .lineLimit(1)
            // 性格 tags
            Text(summary.species)
                .font(.caption)
                .foregroundColor(.secondary)
            // 操作
            HStack {
                Spacer()
                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.red)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .confirmationDialog("删除 \(summary.name)？", isPresented: $showDeleteConfirm) {
            Button("删除", role: .destructive) { onDelete() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该 pet 的所有数据将被永久删除（不可恢复）。")
        }
    }

    private var thumbnail: some View {
        // 缩略图：用 idle state 缩略图，fallback 用首字符
        // 直接读 manifest 解析 idle 路径（不跑完整 PetProfileLoader —— 主线程快路径）
        let assetURL = resolveIdleAssetURL(id: summary.id)
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.gray.opacity(0.2))
                .frame(height: 120)
            if let url = assetURL, let nsImage = NSImage(contentsOf: url) {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
            } else {
                Text(String(summary.name.first ?? "?"))
                    .font(.system(size: 48, weight: .bold))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func resolveIdleAssetURL(id: String) -> URL? {
        let manifest = PetStore.shared.manifestURL(for: id)
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        guard let p = try? ProfileIO.decodeV1(from: manifest) else { return nil }
        let profileRoot = manifest.deletingLastPathComponent()
        return URL(fileURLWithPath: p.visual.states.idle, relativeTo: profileRoot).standardizedFileURL
    }
}

// MARK: - PetEditorView

struct PetEditorView: View {
    @ObservedObject var viewModel: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("名字") {
                    TextField("Pet 名字", text: $viewModel.draft.name)
                }

                if case .create = viewModel.editorMode {
                    Section("基于 sample") {
                        Picker("Sample", selection: $viewModel.draft.sampleID) {
                            ForEach(viewModel.availableSamples) { s in
                                Text(s.displayName).tag(s.id)
                            }
                        }
                    }
                }

                Section("性格 tags") {
                    HStack {
                        ForEach(["calm", "warm", "playful", "sarcastic", "gentle", "deadpan"], id: \.self) { tag in
                            Toggle(tag, isOn: Binding(
                                get: { viewModel.draft.personalityTags.contains(tag) },
                                set: { on in
                                    if on { viewModel.draft.personalityTags.append(tag) }
                                    else { viewModel.draft.personalityTags.removeAll { $0 == tag } }
                                }
                            ))
                            .toggleStyle(.button)
                        }
                    }
                }

                Section("Voice style") {
                    Picker("Tone", selection: $viewModel.draft.voiceTone) {
                        Text("neutral").tag("neutral")
                        Text("warm-gentle").tag("warm-gentle")
                        Text("cold-sarcastic").tag("cold-sarcastic")
                        Text("drawl-deadpan").tag("drawl-deadpan")
                        Text("electronic-haughty").tag("electronic-haughty")
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 480, minHeight: 360)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        viewModel.cancelEditor()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        viewModel.commitEditor()
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(viewModel.draft.name.isEmpty)
                }
            }
        }
    }

    private var navigationTitle: String {
        switch viewModel.editorMode {
        case .none: return ""
        case .create: return "新建 pet"
        case .edit: return "编辑 pet"
        }
    }
}

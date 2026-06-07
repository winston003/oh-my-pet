// HouseView.swift
// HouseView — Pet 主页（顶栏 + 4 tabs + Export 按钮）
//
// UI（来自任务描述）：
//   - 顶栏：返回 + pet 名字 + 性格 tags + "显示桌面" + Edit / Delete 按钮（PetEditDeleteButtons）
//   - 主体：tab 切换
//     - Tab 1 "主页"：状态图 gallery（5 缩略图）+ voice 摘要 + 当前状态
//     - Tab 2 "记忆"：focus/task 完成的记忆列表
//     - Tab 3 "贴纸"：stickers + room objects grid
//     - Tab 4 "历史"：generation history 时间线
//   - 底部：Export Pet Profile 按钮
//
// 数据加载（read-only）：
//   - manifest + 5 states：PetStore.load(id:) → LoadedPetProfile
//   - voice 摘要：manifest.audio.voiceStyle
//   - memories：PetStore.loadMemories(petID:)
//   - today companion record：PetStore.todayMemories(petID:)
//   - stickers：PetStore.loadStickers(petID:)
//   - generation history：PetStore.loadGenerationHistory(petID:)
//   - 写盘（创建 memory / sticker / generation entry）属 P2-F；本屏不写
//
// Export：
//   - PetStore.export(profileID:to:) → .omppet 文件
//   - SwiftUI 弹 NSSavePanel（macOS 原生）让用户选保存位置
//
// 不做：
//   - 不实现 add memory / sticker UI（属 P2-F）
//   - 不实现 PetPanel 启动（PetStore 之外；可选在底部"显示桌面"按钮触发）
//

import SwiftUI
import AppKit
import PetProfile
import PetProfileRuntime
import PetProfileOnboarding

// MARK: - HouseViewModel

// 不加 @MainActor —— 同 StudioViewModel，跟 OnboardingFlow pattern 对齐
public final class HouseViewModel: ObservableObject {
    @Published public var petID: String
    @Published public var profile: LoadedPetProfile?
    @Published public var memories: [PetMemory] = []
    @Published public var todayCompanions: [PetMemory] = []
    @Published public var stickers: [PetSticker] = []
    @Published public var generationHistory: [GenerationHistoryEntry] = []
    @Published public var currentState: String = "idle"
    @Published public var error: String?
    @Published public var exportURL: URL?
    @Published public var wasDeleted: Bool = false

    public let store: PetStore

    public init(petID: String, store: PetStore = .shared) {
        self.petID = petID
        self.store = store
    }

    public func reload() {
        do {
            let loaded = try store.load(id: petID)
            profile = loaded
            memories = try store.loadMemories(petID: petID)
            todayCompanions = try store.todayMemories(petID: petID)
            stickers = try store.loadStickers(petID: petID)
            generationHistory = try store.loadGenerationHistory(petID: petID)
            error = nil
        } catch {
            self.error = "加载 Pet House 失败：\(error.localizedDescription)"
        }
    }

    public func delete() {
        do {
            try store.delete(id: petID)
            wasDeleted = true
        } catch {
            self.error = "删除 pet 失败：\(error.localizedDescription)"
        }
    }

    /// 触发 NSSavePanel 让用户选 .omppet 输出位置，然后调 store.export
    public func runExport() {
        let panel = NSSavePanel()
        panel.title = "Export Pet Profile"
        panel.nameFieldStringValue = "\(petID).omppet"
        panel.allowedContentTypes = []  // 用扩展名过滤（.omppet 是 zip，无 UTType）
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return
        }
        do {
            try store.export(profileID: petID, to: url)
            exportURL = url
            error = nil
        } catch {
            self.error = "导出失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - HouseView

public struct HouseView: View {
    @StateObject public var viewModel: HouseViewModel
    @State private var selectedTab: Tab = .home
    @State public var onBack: () -> Void
    @State public var onShowDesktopPet: (() -> Void)?
    /// 用户点击 "Edit" 按钮 → 通知父 view（通常是 StudioApp）打开编辑器
    /// HouseView 自身不持有 editor state —— 由 parent 决定怎么 present（弹 sheet / 跳 view 等）
    @State public var onRequestEdit: (() -> Void)?
    /// 用户确认删除后 → 通知父 view 退出 HouseView
    @State public var onAfterDelete: (() -> Void)?

    public enum Tab: String, CaseIterable, Identifiable {
        case home = "主页"
        case memories = "记忆"
        case stickers = "贴纸"
        case history = "历史"
        public var id: String { rawValue }
    }

    public init(
        viewModel: HouseViewModel,
        onBack: @escaping () -> Void = {},
        onShowDesktopPet: (() -> Void)? = nil,
        onRequestEdit: (() -> Void)? = nil,
        onAfterDelete: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: viewModel)
        self.onBack = onBack
        self.onShowDesktopPet = onShowDesktopPet
        self.onRequestEdit = onRequestEdit
        self.onAfterDelete = onAfterDelete
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tabBar
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, minHeight: 540)
        .onAppear {
            if viewModel.profile == nil {
                viewModel.reload()
            }
        }
        .onChange(of: viewModel.wasDeleted) { newValue in
            if newValue {
                onAfterDelete?()
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
        .alert("已导出", isPresented: Binding(
            get: { viewModel.exportURL != nil },
            set: { if !$0 { viewModel.exportURL = nil } }
        )) {
            Button("OK") { viewModel.exportURL = nil }
        } message: {
            Text(viewModel.exportURL?.path ?? "")
        }
    }

    // MARK: - header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("house-back-button")

            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.profile?.manifest.name ?? "加载中…")
                    .font(.largeTitle.weight(.semibold))
                Text(personalityTagsText)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                onShowDesktopPet?()
            } label: {
                Label("显示桌面", systemImage: "macwindow")
            }
            .buttonStyle(.bordered)
            .disabled(onShowDesktopPet == nil)
            .accessibilityIdentifier("house-show-desktop-button")
            // 顶栏：edit / delete 按钮（共享 PetCommands 实现 + 二次确认 dialog）
            // 走 toolbar 风格（文字 + 图标）
            if let onEdit = onRequestEdit {
                PetEditDeleteButtons(
                    onEdit: onEdit,
                    onDelete: { viewModel.delete() },
                    style: .toolbar
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private var personalityTagsText: String {
        guard let tags = viewModel.profile?.manifest.persona.backstoryTags, !tags.isEmpty else {
            return "（无 tags）"
        }
        return tags.joined(separator: " · ")
    }

    // MARK: - tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(HouseView.Tab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    Text(tab.rawValue)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 18)
                        .background(
                            Rectangle()
                                .fill(selectedTab == tab ? Color.accentColor.opacity(0.15) : Color.clear)
                        )
                        .foregroundColor(selectedTab == tab ? .accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
    }

    // MARK: - content

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .home:
            HomeTabView(viewModel: viewModel)
        case .memories:
            MemoriesTabView(viewModel: viewModel)
        case .stickers:
            StickersTabView(viewModel: viewModel)
        case .history:
            HistoryTabView(viewModel: viewModel)
        }
    }

    // MARK: - footer

    private var footer: some View {
        HStack {
            Text("Pet ID: \(viewModel.petID)")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                viewModel.runExport()
            } label: {
                Label("Export Pet Profile", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }
}

// MARK: - HomeTabView

struct HomeTabView: View {
    @ObservedObject var viewModel: HouseViewModel

    private let states = ["idle", "focus", "happy", "tired", "celebrate"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("状态图 gallery")
                    .font(.headline)
                stateGallery
                Divider()
                Text("Voice 摘要")
                    .font(.headline)
                voiceSummary
                Divider()
                Text("今天和 pet 的互动")
                    .font(.headline)
                todayCompanionsSection
            }
            .padding(24)
        }
    }

    private var stateGallery: some View {
        let visualURLs = viewModel.profile?.visualAssetURLs ?? [:]
        return HStack(spacing: 12) {
            ForEach(states, id: \.self) { s in
                VStack(spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.2))
                            .frame(width: 96, height: 96)
                        if let url = visualURLs[s], let nsImage = NSImage(contentsOf: url) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 96, height: 96)
                        } else {
                            Text(s.prefix(1))
                                .font(.title2)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text(s)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var voiceSummary: some View {
        if let audio = viewModel.profile?.manifest.audio {
            VStack(alignment: .leading, spacing: 6) {
                Text("Provider: \(audio.ttsProvider)")
                Text("Voice: \(audio.ttsVoice)")
                Text("Tone: \(audio.voiceStyle.tone)")
                Text(String(format: "Pitch: %.2f · Speed: %.2f · Energy: %@",
                            audio.voiceStyle.pitch, audio.voiceStyle.speed,
                            audio.voiceStyle.energy.rawValue))
                Text("Catchphrases: \(audio.catchphrases.count)")
            }
            .font(.body)
        } else {
            Text("（无 voice 摘要）").foregroundColor(.secondary)
        }
    }

    private var todayCompanionsSection: some View {
        Group {
            if viewModel.todayCompanions.isEmpty {
                Text("今天还没有互动。")
                    .foregroundColor(.secondary)
            } else {
                ForEach(viewModel.todayCompanions) { m in
                    HStack {
                        Image(systemName: iconFor(m.kind))
                        VStack(alignment: .leading) {
                            Text(m.title).font(.body)
                            if let d = m.detail {
                                Text(d).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private func iconFor(_ kind: PetMemory.Kind) -> String {
        switch kind {
        case .focusComplete: return "target"
        case .taskComplete: return "checkmark.circle"
        case .firstMeet: return "sparkles"
        case .shared: return "heart"
        }
    }
}

// MARK: - MemoriesTabView

struct MemoriesTabView: View {
    @ObservedObject var viewModel: HouseViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.memories.isEmpty {
                    Text("（暂无记忆 — P2-F 阶段会写入）")
                        .foregroundColor(.secondary)
                        .padding(24)
                } else {
                    ForEach(viewModel.memories) { m in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: iconFor(m.kind))
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(m.title).font(.headline)
                                if let d = m.detail {
                                    Text(d).font(.body).foregroundColor(.secondary)
                                }
                                Text(m.createdAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    private func iconFor(_ kind: PetMemory.Kind) -> String {
        switch kind {
        case .focusComplete: return "target"
        case .taskComplete: return "checkmark.circle"
        case .firstMeet: return "sparkles"
        case .shared: return "heart"
        }
    }
}

// MARK: - StickersTabView

struct StickersTabView: View {
    @ObservedObject var viewModel: HouseViewModel

    private let columns: [GridItem] = Array(
        repeating: GridItem(.flexible(), spacing: 12),
        count: 4
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("贴纸")
                    .font(.headline)
                if stickers(.sticker).isEmpty {
                    Text("（暂无贴纸）").foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(stickers(.sticker)) { s in
                            stickerCell(s)
                        }
                    }
                }
                Divider()
                Text("房间物件")
                    .font(.headline)
                if stickers(.roomObject).isEmpty {
                    Text("（暂无房间物件）").foregroundColor(.secondary)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(stickers(.roomObject)) { s in
                            stickerCell(s)
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func stickers(_ kind: PetSticker.Kind) -> [PetSticker] {
        viewModel.stickers.filter { $0.kind == kind }
    }

    private func stickerCell(_ s: PetSticker) -> some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 80, height: 80)
                if let path = s.assetPath, let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                } else {
                    Text(String(s.name.first ?? "?"))
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
            }
            Text(s.name)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

// MARK: - HistoryTabView

struct HistoryTabView: View {
    @ObservedObject var viewModel: HouseViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if viewModel.generationHistory.isEmpty {
                    Text("（暂无生成记录）")
                        .foregroundColor(.secondary)
                        .padding(24)
                } else {
                    ForEach(viewModel.generationHistory) { e in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: iconFor(e.kind))
                                .frame(width: 24)
                                .foregroundColor(.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(e.summary).font(.body)
                                HStack {
                                    Text(e.kind.rawValue)
                                        .font(.caption)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.gray.opacity(0.2))
                                        )
                                    Text(e.createdAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color(NSColor.controlBackgroundColor))
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    private func iconFor(_ kind: GenerationHistoryEntry.Kind) -> String {
        switch kind {
        case .visual: return "photo"
        case .state: return "face.smiling"
        case .voiceStyle: return "speaker.wave.2"
        case .voiceClone: return "waveform"
        }
    }
}

// PetCommands.swift
// PetCommands — 跨 view 共享的 edit / delete 入口（消重 + 单一来源）
//
// 用途：
//   - `PetEditDeleteButtons` 是一个独立的 SwiftUI View，把"编辑"和"删除"按钮 + 二次确认
//     dialog 集中在一处。HouseView 顶栏 / 未来其它 view 都能用，避免每个 view 各自重写。
//   - 删除走 `confirmationDialog` 强制二次确认（**绝不**静默删除 —— 用户真正拥有 pet，
//     P3 边界）。
//   - 编辑只触发回调，不在内部承担 editor state —— 由调用方决定怎么 present editor。
//
// 设计原则：
//   - View 自身是纯 stateless（@State 仅用于 dialog 开关）。
//   - 行为通过 closure 注入，调用方决定具体写盘逻辑（PetStore.update / .delete / 弹 editor）。
//   - accessibilityIdentifier：edit → "house-edit-button"，delete → "house-delete-button"
//     （test 可直接定位）。
//
// 不做：
//   - 不接真 LLM
//   - 不写盘 —— 只触发回调
//   - 不修改 PetProfileKit / PetProfileRuntime 等上游 package
//

import SwiftUI

// MARK: - PetEditDeleteButtons

/// 共享的 "编辑 + 删除" 按钮组 + 二次确认 dialog。
/// - 用法：在 view 内嵌一个 `PetEditDeleteButtons(onEdit: ..., onDelete: ...)`，
///         onEdit / onDelete 由调用方注入具体行为。
/// - 删除走 `confirmationDialog` 二次确认；用户取消则**不**触发 onDelete。
public struct PetEditDeleteButtons: View {
    public let onEdit: () -> Void
    public let onDelete: () -> Void
    public let confirmMessage: String
    public let style: Style

    @State private var showDeleteConfirm = false

    public enum Style: Equatable {
        /// 文字 + 图标（顶栏 / toolbar 用）
        case toolbar
        /// 只显示图标（卡片用 — 现阶段不推荐；本 task 不在卡片上用）
        case iconOnly
    }

    public init(
        onEdit: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        confirmMessage: String = "该 pet 的所有数据将被永久删除（不可恢复）。",
        style: Style = .toolbar
    ) {
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.confirmMessage = confirmMessage
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 8) {
            editButton
            deleteButton
        }
        .confirmationDialog("删除此 pet？", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                onDelete()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(confirmMessage)
        }
    }

    @ViewBuilder
    private var editButton: some View {
        switch style {
        case .toolbar:
            Button {
                onEdit()
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .buttonStyle(.bordered)
            .help("编辑 pet")
            .accessibilityIdentifier("house-edit-button")
        case .iconOnly:
            Button {
                onEdit()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("编辑 pet")
            .accessibilityIdentifier("house-edit-button")
        }
    }

    @ViewBuilder
    private var deleteButton: some View {
        switch style {
        case .toolbar:
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .help("删除 pet")
            .accessibilityIdentifier("house-delete-button")
        case .iconOnly:
            Button {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.red)
            .help("删除 pet")
            .accessibilityIdentifier("house-delete-button")
        }
    }
}

// SelectionTrigger.swift
// SelectionTrigger — 菜单栏 NSStatusItem 触发器
//
// 责任（spec §3.1 P5 "user-triggered" + P2-L-2 任务描述）：
//   - 创建一个 NSStatusItem（菜单栏图标）
//   - 菜单里挂 "Ask about selection…" NSMenuItem
//   - 用户点击 → 调用回调（onTrigger）
//   - 回调由调用方（PetProfileStudio / PetWindowController）实现
//     — 实际读剪贴板 + 抓 FrontmostAppCapture + 弹 SelectionPanel
//
// 设计要点：
//   - class + 可注入回调（init(onTrigger:)）
//   - 启动时 createStatusItem；停止时 remove
//   - **不**写真实 global hotkey（spec §1 P5 "user-triggered" — 菜单栏点就够；
//     真要加 hotkey 走 Carbon API 申请 Input Monitoring / Accessibility，
//     留待 P2-M Accessibility 流程一起做）
//   - **不**在触发瞬间做剪贴板读取（spec P5 "user-triggered, not polling"）——
//     读剪贴板逻辑在回调里，调用方拿到 trigger 之后才读
//   - status bar icon 用 system symbol "wand.and.stars"（siri 用过的；
//     fall back 到 text 标签如果 SF Symbol 不可用）
//   - menu 还有一个 "About" / "Quit" 之类的占位 item 在 P2-M 加；
//     MVP 只放 "Ask about selection…"
//
// 不做：
//   - 不写 Carbon RegisterEventHotKey（全局快捷键；需要 Input Monitoring / Accessibility）
//   - 不在 init 时读剪贴板（polling）
//   - 不调 NSWorkspace 抓 frontmost app（在回调里做；保持 trigger 本身轻量）
//   - 不 import PetProfileBrain / PetProfileStudio
//     （Runtime 是 AppKit 层；下游消费 trigger 的代码负责装到 AI 调用）
//
// 测试关注点：
//   - start() 创建 status item（statusItem != nil）
//   - start() 后 menu 含 "Ask about selection…"
//   - stop() 移除 status item
//   - 模拟点击 "Ask about selection…" → onTrigger 被调一次
//   - 不读剪贴板 / 不抓 NSWorkspace（trigger 是纯粹的 UI 触发器）
//
// **adversarial probe**：
//   - grep "kAX\|AXUIElement\|accessibility" PetProfileRuntime/Sources — 0 命中
//   - grep "NSPasteboard" PetProfileRuntime/Sources/SelectionTrigger.swift — 0 命中
//     （剪贴板读取是回调里做的，不在 trigger 本体）
//   - grep "RegisterEventHotKey\|RegisterEvent" PetProfileRuntime/Sources — 0 命中

import AppKit
import Foundation

public final class SelectionTrigger {

    // MARK: - Public callback

    /// 用户点 "Ask about selection…" 时被调。
    /// 回调在主线程触发（NSMenuItem 行为）。
    /// 调用方负责：
    ///   1. 读 NSPasteboard.general.string(forType: .string)
    ///   2. 抓 FrontmostAppCapture.snapshot()
    ///   3. 弹 SelectionPanel
    public typealias TriggerHandler = @MainActor () -> Void

    private let onTrigger: TriggerHandler

    // MARK: - State

    private var statusItem: NSStatusItem?
    private let menuItemTitle: String

    // MARK: - Init

    public init(
        onTrigger: @escaping TriggerHandler,
        menuItemTitle: String = "Ask about selection…"
    ) {
        self.onTrigger = onTrigger
        self.menuItemTitle = menuItemTitle
    }

    // MARK: - Lifecycle

    /// 启动：创建 NSStatusItem + 挂 menu
    @MainActor
    public func start() {
        // 防御：重复 start() 不应该重复创建
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        // SF Symbol "wand.and.stars" — 14+
        if let button = item.button {
            if let image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: "Selection Assistant") {
                button.image = image
            } else {
                // Fallback for older macOS / 不可用 SF Symbol
                button.title = "🐾"
            }
        }

        // Menu
        let menu = NSMenu(title: "Selection Assistant")
        let askItem = NSMenuItem(
            title: menuItemTitle,
            action: #selector(handleAskItemClicked(_:)),
            keyEquivalent: ""
        )
        askItem.target = self
        menu.addItem(askItem)

        item.menu = menu
        self.statusItem = item
    }

    /// 停止：移除 NSStatusItem
    @MainActor
    public func stop() {
        guard let item = statusItem else { return }
        NSStatusBar.system.removeStatusItem(item)
        statusItem = nil
    }

    // MARK: - Status

    @MainActor
    public var isRunning: Bool { statusItem != nil }

    /// 给测试 / debug 用：当前 status item 的 menu（start 后非空）
    @MainActor
    public var currentMenu: NSMenu? { statusItem?.menu }

    /// 给测试 / debug 用：当前 status item 第一个 menu item 的 title
    @MainActor
    public var currentFirstMenuItemTitle: String? {
        statusItem?.menu?.items.first?.title
    }

    // MARK: - Internal handler

    @objc @MainActor
    private func handleAskItemClicked(_ sender: Any?) {
        onTrigger()
    }
}

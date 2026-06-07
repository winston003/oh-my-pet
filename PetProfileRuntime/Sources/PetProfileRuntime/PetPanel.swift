// PetPanel.swift
// 透明悬浮 NSPanel 子类，按 pet-runtime rein agent.md 关键配置
//
// 关键配置（来自 .harness/reins/pet-runtime/agent.md）：
//   - styleMask: .borderless + .nonactivatingPanel + .resizable
//   - backgroundColor: .clear
//   - isOpaque: false
//   - hasShadow: false
//   - level: .floating
//   - collectionBehavior: .canJoinAllSpaces + .fullScreenAuxiliary + .stationary
//   - hidesOnDeactivate: true
//   - becomesKeyOnlyIfNeeded: true
//   - becomesKeyOnMainWindow: false
//   - isMovableByWindowBackground: true
//
// 测试可读性：把每个 key 配成 public getter，单元测试可以逐项校验。
//
// 不做：
//   - 实际显示（main entry 不要求 GUI 实际出现；只 build + 启动）
//   - 事件路由 / 鼠标命中 / 拖拽手势（后续 plan）
//   - 多通道状态机
//
// 设计决策：
//   - NSPanel 而不是 NSWindow：天然支持 nonactivatingPanel + floating level
//   - 用 contentView 装 NSImageView 展示 idle 占位 PNG
//   - 默认 160x160，可拖拽 resize
//   - 显式 init 不抛错（pet profile 已经在 loader 阶段校验过；asset 缺失由占位 PNG 兜底）

import AppKit
import PetProfile

public final class PetPanel: NSPanel {

    // MARK: - 内部状态

    private let loadedProfile: LoadedPetProfile
    /// 当前展示的 visual state，初始 idle。后续状态机接管。
    public private(set) var currentState: String = "idle"
    /// 占位 image view（contentView 唯一子 view）
    private let imageView: NSImageView

    // pet-runtime rein agent.md 列了 "becomesKeyOnMainWindow: false"。
    // AppKit 的 NSWindow 没有这个属性。语义最接近的是 "即使主窗口变化也不抢 main 状态"，
    // 实现方式：override canBecomeMain → false。
    // 公开这个 stored property 让测试可断言 + 后续 plan 改语义不会破坏 caller。
    public let becomesKeyOnMainWindow: Bool = false

    // MARK: - Init

    /// 用 LoadedPetProfile 初始化 panel。不抛错。
    public init(profile: LoadedPetProfile, frame: NSRect = NSRect(x: 200, y: 200, width: 160, height: 160)) {
        self.loadedProfile = profile

        // 先准备 imageView（init 期间不能调 self）
        let iv = NSImageView(frame: NSRect(origin: .zero, size: frame.size))
        iv.imageScaling = .scaleProportionallyUpOrDown
        iv.imageAlignment = .alignCenter
        iv.translatesAutoresizingMaskIntoConstraints = false
        iv.wantsLayer = true
        iv.layer?.backgroundColor = NSColor.clear.cgColor
        self.imageView = iv

        // 标准 NSPanel 初始化（borderless + nonactivatingPanel + resizable）
        let style: NSWindow.StyleMask = [.borderless, .nonactivatingPanel, .resizable]
        super.init(
            contentRect: frame,
            styleMask: style,
            backing: .buffered,
            defer: false
        )

        // 按 rein agent.md 关键配置逐项设置
        // 关键路径：窗口层级 & 跨 Space 行为
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        // 关键路径：透明 & 无阴影
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        // 不抢焦点
        self.hidesOnDeactivate = true
        self.becomesKeyOnlyIfNeeded = true
        // becomesKeyOnMainWindow=false → AppKit 用 canBecomeMain=false 实现
        // （本类在下方 override）

        // 关键路径：背景可拖
        self.isMovableByWindowBackground = true
        // 鼠标默认穿透到下层窗口的事件（None = 不透传，event 仍由 panel 收）
        // 命中区由 imageView 的 hit test 决定；如果要"全透明处点击穿透"在事件路由 plan 里处理
        self.ignoresMouseEvents = false

        // 初始大小约束
        self.minSize = NSSize(width: 64, height: 64)
        self.maxSize = NSSize(width: 512, height: 512)

        // contentView：透明 layer + imageView 子 view
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        container.addSubview(iv)
        NSLayoutConstraint.activate([
            iv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            iv.topAnchor.constraint(equalTo: container.topAnchor),
            iv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.contentView = container

        // 加载 idle 占位图
        applyIdleAsset()
    }

    /// 不允许走默认 init
    @available(*, unavailable)
    public override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        fatalError("use init(profile:frame:) instead")
    }

    // MARK: - Show

    /// 显示 panel（先 orderFront，避免 orderFrontRegardless 抢焦点）。
    /// 不强求 NSApp.run() —— main entry 可以 show 后立即退出。
    public func show() {
        self.orderFrontRegardless()
        // 不抢焦点：.nonactivatingPanel + becomesKeyOnlyIfNeeded 已经让 orderFront 不强 key 状态
    }

    // MARK: - asset switching

    /// 加载 visual.idle 占位图（默认启动时调用）。后续状态机接管。
    private func applyIdleAsset() {
        if let url = loadedProfile.visualAssetURLs["idle"],
           let image = NSImage(contentsOf: url) {
            imageView.image = image
        } else {
            imageView.image = nil
        }
    }

    /// 切换 visual state。返回是否切换成功（asset 缺失返回 false，但不抛错）。
    @discardableResult
    public func switchVisualState(_ state: String) -> Bool {
        guard let url = loadedProfile.visualAssetURLs[state],
              let image = NSImage(contentsOf: url) else {
            return false
        }
        imageView.image = image
        currentState = state
        return true
    }

    // MARK: - AppKit 关键路径 override

    /// pet-runtime rein agent.md: "becomesKeyOnMainWindow: false"
    /// AppKit 的等价物是 canBecomeMain → false。panel 永远不会成为 main window，
    /// 即使有其他窗口 main 了也不会被强制拉过来。
    public override var canBecomeMain: Bool { false }

    /// 默认 canBecomeKey 保持 true（要能响应 right-click menu / 菜单栏命令）

    // MARK: - Public getters（测试用）

    public var profile: LoadedPetProfile { loadedProfile }

    public var styleMaskDescription: String {
        var parts: [String] = []
        if self.styleMask.contains(.borderless) { parts.append("borderless") }
        if self.styleMask.contains(.nonactivatingPanel) { parts.append("nonactivatingPanel") }
        if self.styleMask.contains(.resizable) { parts.append("resizable") }
        if self.styleMask.contains(.titled) { parts.append("titled") }
        if self.styleMask.contains(.closable) { parts.append("closable") }
        if self.styleMask.contains(.miniaturizable) { parts.append("miniaturizable") }
        return parts.joined(separator: "+")
    }

    public var levelDescription: String {
        // NSWindow.Level 是 typealias Int，常量在 NSWindow 上。直接比对 rawValue
        let v = self.level
        if v == NSWindow.Level.floating { return "floating" }
        if v == NSWindow.Level.normal { return "normal" }
        if v == NSWindow.Level.modalPanel { return "modalPanel" }
        if v == NSWindow.Level.mainMenu { return "mainMenu" }
        if v == NSWindow.Level.statusBar { return "statusBar" }
        if v == NSWindow.Level.popUpMenu { return "popUpMenu" }
        if v == NSWindow.Level.screenSaver { return "screenSaver" }
        return "custom(\(v))"
    }

    public var collectionBehaviorDescription: String {
        var parts: [String] = []
        let b = self.collectionBehavior
        if b.contains(.canJoinAllSpaces) { parts.append("canJoinAllSpaces") }
        if b.contains(.fullScreenAuxiliary) { parts.append("fullScreenAuxiliary") }
        if b.contains(.stationary) { parts.append("stationary") }
        if b.contains(.managed) { parts.append("managed") }
        if b.contains(.transient) { parts.append("transient") }
        if b.contains(.ignoresCycle) { parts.append("ignoresCycle") }
        return parts.joined(separator: "+")
    }

    /// 把 panel 全部关键配置 dump 成可读字符串（用于 main entry 打印 / debug）
    public func configurationDescription() -> String {
        return """
        PetPanel configuration:
          profile.id = \(loadedProfile.manifest.id.raw)
          profile.name = \(loadedProfile.manifest.name)
          styleMask = \(styleMaskDescription)
          backgroundColor = \(String(describing: self.backgroundColor))
          isOpaque = \(self.isOpaque)
          hasShadow = \(self.hasShadow)
          level = \(levelDescription)
          collectionBehavior = \(collectionBehaviorDescription)
          hidesOnDeactivate = \(self.hidesOnDeactivate)
          becomesKeyOnlyIfNeeded = \(self.becomesKeyOnlyIfNeeded)
          becomesKeyOnMainWindow = \(self.becomesKeyOnMainWindow)
          isMovableByWindowBackground = \(self.isMovableByWindowBackground)
          ignoresMouseEvents = \(self.ignoresMouseEvents)
          minSize = \(self.minSize), maxSize = \(self.maxSize)
          currentState = \(currentState)
        """
    }
}

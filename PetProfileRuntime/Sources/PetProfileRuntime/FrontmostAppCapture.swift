// FrontmostAppCapture.swift
// FrontmostAppCapture — 抓 frontmost app 上下文
//
// 责任（spec §1 P5 权限分层 + P2-L-2 任务描述）：
//   - 用 NSWorkspace.shared.frontmostApplication 拿 frontmost app
//   - 抽 AppContextSnapshot（bundleID / appName / windowTitle? / capturedAt）
//   - **不**读 windowTitle（避免偷偷抓窗口标题；属于 Layer 2 Accessibility 能力）
//   - 测试可注入（见 FrontmostAppCaptureTests 用 NSPasteboard / frontmost app
//     替换路径覆盖；snapshot 本体是纯函数）
//
// 设计要点：
//   - struct + Sendable（纯函数，无 mutable state）
//   - 静态方法 snapshot() 返回 AppContextSnapshot（PetProfileBrain 包定义的类型）
//   - **不** import PetProfileBrain（Runtime 是 AppKit 层；具体类型在调用方契约里）
//   - 实际拿 frontmost app 用 NSWorkspace.shared.frontmostApplication；
//     这没有"读窗口标题"的副作用；windowTitle 在 P2-M 加 Accessibility 申请后
//     再单独加 snapshot(windowTitle: Bool) 重载
//   - fallback "Unknown" 是给"没 frontmost app"的边界（罕见；CI / 单元测试可能撞）
//
// 不做：
//   - 不 import PetProfileBrain（Runtime 不依赖 Brain；调用方负责把
//     FrontmostAppCapture.snapshot() 装进 TextCompletionRequest.appContext）
//   - 不读 Accessibility / 窗口标题（spec §1 P5 红线；留给 P2-M）
//   - 不调 system_profiler / osascript / 类似"用户不知情"工具
//   - 不持久化 snapshot（不写盘；调用方持引用即可）
//
// 测试关注点：
//   - snapshot 在 NSWorkspace 没 frontmost app 时（mock path）不 crash
//   - bundleID 为 nil 时不 crash（unknown app）
//   - windowTitle 永远是 nil（MVP 不读）
//   - capturedAt 是 Date() 时刻（两次调用 capturedAt 不同 —— 断言不严格相等）

import AppKit
import Foundation

public struct FrontmostAppCapture: Sendable {

    /// 拿一次 frontmost app 上下文。
    ///
    /// - Returns: AppContextSnapshot
    ///   - bundleID: app.bundleIdentifier（可能为 nil：未注册 / headless 进程）
    ///   - appName: app.localizedName ?? "Unknown"
    ///   - windowTitle: 永远 nil（MVP 不读窗口标题；spec §1 P5 红线）
    ///   - capturedAt: 调用时刻 Date()
    ///
    /// **不**抛错：NSWorkspace.frontmostApplication 本身就可能返回 nil
    /// （极少见；headless / CI / 自动化环境），fallback 到 "Unknown" app
    /// + nil bundleID 是安全的。
    public static func snapshot() -> Snapshot {
        let app = NSWorkspace.shared.frontmostApplication
        guard let app else {
            return Snapshot(
                bundleID: nil,
                appName: "Unknown",
                windowTitle: nil,
                capturedAt: Date()
            )
        }
        return Snapshot(
            bundleID: app.bundleIdentifier,
            appName: app.localizedName ?? "Unknown",
            // windowTitle: 不读
            // 解释：读取 frontmost app 的窗口标题需要 AXUIElementCopyAttributeValue(kAXWindowAttribute),
            //      属于 Accessibility 权限（spec §1 P5 Layer 2）。
            //      MVP 触发选区走 Layer 3（user-triggered + 显式 confirm），不偷偷读窗口。
            windowTitle: nil,
            capturedAt: Date()
        )
    }

    /// 本地 AppContext 类型 — Runtime 不 import PetProfileBrain；
    /// 调用方负责把 Snapshot 转成 PetProfileBrain.AppContextSnapshot
    /// （字段一一对应；可 Convertible）。
    ///
    /// 这样设计的好处：
    ///   - PetProfileRuntime 不反向依赖 PetProfileBrain（PetProfileBrain 在 Core 层；
    ///     Runtime 是 AppKit 层；spec §4.2 "依赖方向" 红线）
    ///   - 测试可独立 mock Snapshot（不耦合 Brain）
    public struct Snapshot: Sendable, Equatable, Hashable, Codable {
        public let bundleID: String?
        public let appName: String
        public let windowTitle: String?
        public let capturedAt: Date

        public init(
            bundleID: String?,
            appName: String,
            windowTitle: String?,
            capturedAt: Date
        ) {
            self.bundleID = bundleID
            self.appName = appName
            self.windowTitle = windowTitle
            self.capturedAt = capturedAt
        }
    }
}

// MARK: - 与 PetProfileBrain.AppContextSnapshot 的桥接
//
// 这里不直接 import PetProfileBrain（避免反向依赖）。
// 转换在 SelectionCoordinator 那一层做（PetProfileStudio 包）——
// 它 import 两边，可以做 SelectionTrigger.Snapshot → AppContextSnapshot 的转换。
//
// 字段一一对应：
//   FrontmostAppCapture.Snapshot  →  PetProfileBrain.AppContextSnapshot
//   bundleID   (String?)          →  bundleID   (String?)
//   appName    (String)           →  appName    (String)
//   windowTitle(String?)          →  windowTitle(String?)  // 永远 nil
//   capturedAt (Date)             →  capturedAt (Date)

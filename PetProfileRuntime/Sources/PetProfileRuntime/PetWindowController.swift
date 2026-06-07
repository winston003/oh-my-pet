// PetWindowController.swift
// 整合 loader + PetPanel 的高层 API
//
// 责任：
//   - 用 PetProfileLoader 加载 manifest
//   - 用 LoadedPetProfile 构造 PetPanel
//   - 提供 start() / stop() 控制面板
//
// 不做：事件路由、状态机、focus/timer —— 后续 plan

import AppKit
import Foundation
import PetProfile

public final class PetWindowController {
    private let loader = PetProfileLoader()
    private(set) public var panel: PetPanel?
    private(set) public var profile: LoadedPetProfile?

    public init() {}

    /// 从 manifest URL 启动一个 pet panel。返回是否成功。
    @discardableResult
    public func start(with manifestURL: URL) -> Bool {
        do {
            let p = try loader.loadProfile(from: manifestURL)
            self.profile = p
            let panel = PetPanel(profile: p)
            self.panel = panel
            panel.show()
            return true
        } catch {
            FileHandle.standardError.write(Data("PetWindowController.start failed: \(error)\n".utf8))
            return false
        }
    }

    /// 关闭 panel 并清理
    public func stop() {
        panel?.orderOut(nil)
        panel = nil
        profile = nil
    }
}

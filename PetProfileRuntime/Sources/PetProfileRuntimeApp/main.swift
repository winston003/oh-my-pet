// main.swift
// PetProfileRuntimeApp — 命令行入口
//
// 用法：
//   PetProfileRuntimeApp <manifest.json>
//
// 行为：
//   1. 解析参数（必须有 1 个 manifest 路径）
//   2. 用 PetWindowController 启动 panel
//   3. 打印 panel configuration（供人工 / 烟测确认）
//   4. 退出（不 run NSApp，避免依赖 GUI 显示）
//
// 不要求 GUI 实际显示；只验证 build + 启动 + 配置正确。
// 后续 plan 会接入 NSApp.run() + 事件循环。
//
// Exit code:
//   0 = success
//   1 = 参数错误 / 加载失败 / panel 未启动

import Foundation
import AppKit
import PetProfileRuntime

func printUsage() {
    FileHandle.standardError.write(Data("""
    Usage: PetProfileRuntimeApp <manifest.json>
    
    Loads a PetProfile v1 manifest, builds a transparent NSPanel, and exits.
    
    """.utf8))
}

guard CommandLine.arguments.count >= 2 else {
    printUsage()
    exit(1)
}

let manifestPath = CommandLine.arguments[1]
let manifestURL = URL(fileURLWithPath: manifestPath)

guard FileManager.default.fileExists(atPath: manifestURL.path) else {
    FileHandle.standardError.write(Data("manifest not found: \(manifestURL.path)\n".utf8))
    exit(1)
}

let controller = PetWindowController()
guard controller.start(with: manifestURL) else {
    FileHandle.standardError.write(Data("failed to start pet window controller\n".utf8))
    exit(1)
}

guard let panel = controller.panel else {
    FileHandle.standardError.write(Data("panel is nil after start\n".utf8))
    exit(1)
}

print(panel.configurationDescription())
print("[OK] PetProfileRuntimeApp: panel created at \(panel.frame.origin) size \(panel.frame.size)")
exit(0)

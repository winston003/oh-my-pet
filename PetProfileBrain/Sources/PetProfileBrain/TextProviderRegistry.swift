// TextProviderRegistry.swift
// TextProvider 注册中心 — 发现 + 默认 provider 解析
//
// 对应 spec §3.1 "ProviderRegistry 注册式发现；禁止调用方 import 具体 SDK"
//
// 设计要点（与 ImageProviderRegistry 同形 API，方便 P2-L-2 / P2-L-3 复用同一风格）：
//   - 单例（.shared）+ 支持 init 时一次性注册（StudioApp / Brain.bootstrap 时调 registerBuiltIn）
//   - 线程安全：registry 写入只在启动期，运行时 read-only，用 NSLock 兜底
//   - defaultProvider 固定返回 "stub"（无凭据要求，符合 spec P6 BYOK-first）
//     - fallback：若默认被 unregister 掉了，返回**第一个非 requiresAPIKey 的**
//     - 再 fallback：返回**第一个注册的**（保 stable 行为）
//     - 真出现空注册时 fatalError（"registry is empty — 启动期必注册"）
//   - allProviders 按 id 字母序返回（UI 列表稳定）
//   - register 接受 TextProvider；同 id 二次注册覆盖（不抛错，符合 P2-J ImageProviderRegistry 同形）
//
// 不做：
//   - 不在运行时改 default（不允许切换默认；如需新增默认走 register 时覆盖）
//   - 不持久化注册列表（重启 = 重新注册）
//   - 不在 TextProviderRegistry 里 import 具体 provider 模块（Core 层；具体的 StubTextProvider
//     在本 package 内，OpenAITextProvider 在 PetProfileLLM 内；调用方负责传进来）
//

import Foundation

// MARK: - TextProviderRegistry

public final class TextProviderRegistry: @unchecked Sendable {
    /// 全局单例
    public static let shared: TextProviderRegistry = {
        let r = TextProviderRegistry()
        r.registerBuiltInProviders()
        return r
    }()

    private var providers: [String: TextProvider] = [:]
    private let lock = NSLock()
    private let defaultID: String = StubTextProvider.providerID

    public init() {}

    /// 启动期一次性注册：StubTextProvider（默认）。
    /// 注：OpenAITextProvider 来自 PetProfileLLM，不在 Brain 内；调用方需自己 register。
    /// 这里不导入 PetProfileLLM（Brain 是 Core 层；spec §4.2 反向依赖红线）。
    private func registerBuiltInProviders() {
        register(StubTextProvider())
    }

    /// 注册 provider（同 id 覆盖）
    public func register(_ provider: TextProvider) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.id] = provider
    }

    /// 查 provider
    public func provider(for id: String) -> TextProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    /// 默认 provider（"stub"）。
    /// - Falls back 顺序：
    ///   1. providers["stub"]
    ///   2. 第一个 requiresAPIKey == false 的（保证默认不依赖 keychain）
    ///   3. 第一个注册的
    /// - 极端情况（registry 空）抛 fatalError（"registry is empty — 启动期必注册"）
    public var defaultProvider: TextProvider {
        lock.lock()
        defer { lock.unlock() }
        if let def = providers[defaultID] {
            return def
        }
        if let firstNoKey = providers.values.first(where: { !$0.requiresAPIKey }) {
            return firstNoKey
        }
        if let firstAny = providers.values.first {
            return firstAny
        }
        // 真出现这种情况说明启动期 register 失败 / 测试 target 没调 register
        // —— fail fast 远比静默 fallback 安全
        fatalError("TextProviderRegistry is empty; call registerBuiltInProviders() at startup")
    }

    /// 所有 provider（按 id 字母序，UI 列表稳定）
    public var allProviders: [TextProvider] {
        lock.lock()
        defer { lock.unlock() }
        return providers.values.sorted { $0.id < $1.id }
    }

    /// 数量（test / debug 用）
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return providers.count
    }
}

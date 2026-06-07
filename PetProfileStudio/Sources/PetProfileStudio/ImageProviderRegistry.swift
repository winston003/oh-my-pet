// ImageProviderRegistry.swift
// ImageProvider 注册中心 — 发现 + 默认 provider 解析
//
// 对应 spec §3.1 "ProviderRegistry 注册式发现；禁止调用方 import 具体 SDK"
//
// 设计要点：
//   - 单例（.shared）+ 支持 init 时一次性注册（StudioApp 启动时调 registerBuiltIn）
//   - 线程安全：registry 写入只在启动期，运行时 read-only，用 NSLock 兜底
//   - defaultProvider() 固定返回 "upload-local"（无凭据要求，符合 P6 BYOK-first）
//   - allProviders() 按 id 字母序返回（UI 列表稳定）
//
// 不做：
//   - 不在运行时改 default（不允许切换默认；如需新增默认走 register 时覆盖）
//   - 不持久化注册列表（重启 = 重新注册）
//

import Foundation

// MARK: - ImageProviderRegistry

public final class ImageProviderRegistry: @unchecked Sendable {
    /// 全局单例
    public static let shared: ImageProviderRegistry = {
        let r = ImageProviderRegistry()
        r.registerBuiltInProviders()
        return r
    }()

    private var providers: [String: ImageProvider] = [:]
    private let lock = NSLock()
    private let defaultID: String = UploadImageProvider.providerID

    public init() {}

    /// 启动期一次性注册：3 个内置 provider（upload + 2 个 stub）
    /// 注：注册顺序决定 default 兜底（最后注册的同 id 覆盖前一个）。
    /// 这里 fixed 顺序：upload 先，stub 后。
    private func registerBuiltInProviders() {
        register(UploadImageProvider())
        register(OpenAIDALLEImageProvider())
        register(StableDiffusionImageProvider())
    }

    /// 注册 provider（同 id 覆盖）
    public func register(_ provider: ImageProvider) {
        lock.lock()
        defer { lock.unlock() }
        providers[provider.id] = provider
    }

    /// 查 provider
    public func provider(id: String) -> ImageProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[id]
    }

    /// 默认 provider（upload-local）
    /// - Falls back：若默认被 unregister 掉了，返回第一个注册的 provider；
    ///   极端情况下（registry 空）抛 fatalError（"registry is empty — 启动期必注册"）。
    public func defaultProvider() -> ImageProvider {
        lock.lock()
        let firstProvider = providers.values.first
        let def = providers[defaultID] ?? firstProvider
        lock.unlock()

        if let def = def {
            return def
        }
        // 真出现这种情况说明启动期 register 失败 / 测试 target 没调 register
        // —— fail fast 远比静默 fallback 安全
        fatalError("ImageProviderRegistry is empty; call registerBuiltInProviders() at startup")
    }

    /// 所有 provider（按 id 字母序，UI 列表稳定）
    public func allProviders() -> [ImageProvider] {
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

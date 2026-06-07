// KeychainKeyStore.swift
// macOS Keychain BYOK — provider API key 存储层
//
// 关键决策（对齐 pet-brain agent.md "BYOK" + AGENTS.md "Local-First And BYOK"）：
//   - **service 名字固定 `oh-my-pet-llm-keys`**（项目级常量；不暴露给 caller）
//   - **account = provider name**（`"openai"` / `"claude"` / `"openai-compatible:<endpoint>"`）
//   - **kSecAttrAccessible = kSecAttrAccessibleWhenUnlockedThisDeviceOnly**
//     - 不 iCloud 同步（不自动上传 Apple ID 关联的设备列表）
//     - 设备未解锁不可读（用户重启 / 文件保险箱态 → 拒绝）
//     - **不**用 kSecAttrAccessibleAlways / AlwaysThisDeviceOnly（前者已 deprecate；后者违反
//       "fresh-解锁可见"语义）
//   - **class = kSecClassGenericPassword**（通用密码；不做 certificate / identity）
//   - **数据格式 = UTF-8 string**（API key 是 ASCII / token 形式；二进制也支持但不必要）
//
// 测试策略：
//   - `KeychainKeyStore` 内部用 `KeychainBackend` 协议
//   - 真实现：`SecurityFrameworkBackend`（macOS Security framework）
//   - 测试实现：`InMemoryKeychainBackend`（dict 存）
//   - `KeychainKeyStore.shared` = 真后端；测试自己构造 fake backend 的 store
//
// 不做：
//   - 跨设备同步（不写 iCloud Keychain）
//   - Keychain 访问组 / app group 共享（先单 app 跑通；以后 macOS sandbox app 跨进程再说）
//   - API key 加密包装（Keychain 本身就是加密的；AGENTS.md "BYOK" 不要求二次加密）
//   - 改 PetProfileOnboarding Stage 1.5（它仍是 mock keychain ref；真正接 KeychainKeyStore
//     是后续 plan）
//

import Foundation
import Security

// MARK: - Constants

public enum KeychainConstants {
    /// 写死项目级 service 名；所有 provider 共用
    public static let serviceName: String = "oh-my-pet-llm-keys"
}

// MARK: - KeychainBackend 协议

/// 抽象后端，让 `KeychainKeyStore` 既能用真 Security framework，又能用 in-memory mock。
public protocol KeychainBackend: Sendable {
    func save(_ data: Data, account: String) throws
    func load(account: String) throws -> Data?
    func delete(account: String) throws
    func listAccounts() throws -> [String]
}

// MARK: - KeychainError

public enum KeychainError: Error, CustomStringConvertible, Equatable {
    case unhandled(status: OSStatus)
    case itemNotFound
    case invalidData
    case duplicateItem

    public var description: String {
        switch self {
        case .unhandled(let s): return "Keychain unhandled OSStatus \(s)"
        case .itemNotFound: return "Keychain item not found"
        case .invalidData: return "Keychain returned invalid data"
        case .duplicateItem: return "Keychain item already exists"
        }
    }
}

// MARK: - SecurityFrameworkBackend（真实现）

/// macOS Security framework 后端。
/// 单元测试**不要**直接用这个 — 它会写真 keychain；测试用 `InMemoryKeychainBackend`。
public final class SecurityFrameworkBackend: KeychainBackend {

    public init() {}

    public func save(_ data: Data, account: String) throws {
        // 先查：存不存在？
        //   存在 → update；不存在 → add
        // 不走 SecItemUpdate 错误码 25300（itemNotFound）后再 add 的 two-step 模式，
        // 直接 SecItemAdd + error -25299 (duplicate) 触发 delete + retry。
        var query = baseQuery(account: account)
        query[kSecValueData as String] = data

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecDuplicateItem {
            // 已经在 → update
            let attrsToUpdate: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                attrsToUpdate as CFDictionary
            )
            if updateStatus != errSecSuccess {
                throw KeychainError.unhandled(status: updateStatus)
            }
            return
        }

        if status != errSecSuccess {
            throw KeychainError.unhandled(status: status)
        }
    }

    public func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecItemNotFound {
            return nil
        }
        if status != errSecSuccess {
            throw KeychainError.unhandled(status: status)
        }
        guard let data = result as? Data else {
            throw KeychainError.invalidData
        }
        return data
    }

    public func delete(account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.unhandled(status: status)
        }
        // errSecItemNotFound 也算成功（幂等删除）
    }

    public func listAccounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.serviceName,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        if status != errSecSuccess {
            throw KeychainError.unhandled(status: status)
        }
        guard let items = result as? [[String: Any]] else {
            return []
        }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    // MARK: - helpers

    private func baseQuery(account: String) -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.serviceName,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
    }
}

// MARK: - InMemoryKeychainBackend（测试用）

/// 内存版后端，**只**给单元测试用。完全避免污染真 keychain。
public final class InMemoryKeychainBackend: KeychainBackend, @unchecked Sendable {

    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    public init() {}

    public func save(_ data: Data, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[account] = data
    }

    public func load(account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return storage[account]
    }

    public func delete(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: account)
    }

    public func listAccounts() throws -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return Array(storage.keys).sorted()
    }

    /// 测试 helper：清空（fixture 重置）
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
    }
}

// MARK: - KeychainKeyStore

public final class KeychainKeyStore: @unchecked Sendable {

    /// 单例（真 keychain 后端）。**生产路径**用这个。
    /// 测试**不要**用 shared，自己 new 一个 + 传 in-memory backend。
    public static let shared: KeychainKeyStore = KeychainKeyStore(backend: SecurityFrameworkBackend())

    private let backend: KeychainBackend

    public init(backend: KeychainBackend) {
        self.backend = backend
    }

    // MARK: - 公共 API

    /// 存 key（覆盖语义；已存在则替换）
    /// - Parameter key: API key（任意 string；非空）
    /// - Parameter provider: account 名（"openai" / "claude" / "openai-compatible:<endpoint>"）
    public func saveKey(_ key: String, forProvider provider: String) throws {
        guard !key.isEmpty else {
            throw KeychainError.invalidData
        }
        guard !provider.isEmpty else {
            throw KeychainError.invalidData
        }
        let data = Data(key.utf8)
        try backend.save(data, account: provider)
    }

    /// 读 key；不存在 → nil
    public func loadKey(forProvider provider: String) throws -> String? {
        guard !provider.isEmpty else {
            throw KeychainError.invalidData
        }
        guard let data = try backend.load(account: provider) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// 删 key（幂等；不存在不抛错）
    public func deleteKey(forProvider provider: String) throws {
        guard !provider.isEmpty else {
            throw KeychainError.invalidData
        }
        try backend.delete(account: provider)
    }

    /// 列出所有已存 provider key 的 account 名（有序）
    public func listProviders() throws -> [String] {
        return try backend.listAccounts()
    }
}

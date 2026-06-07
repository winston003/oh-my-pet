// LLMProvider.swift
// PetProfileLLM 的 LLM 抽象层
//
// 关键设计：Brain 的 `LLMProvider` 是 **sync** 的（`throws -> String`），本 package 的真
// provider 必须走 URLSession async/await 才能用；所以我们平行引入：
//
//   - `AsyncLLMProvider` — 本 package 的"新"协议，给真 provider 用
//   - `LLMProvider`      — re-export `PetProfileBrain.LLMProvider`，让 caller 无需
//                          同时 import 两个模块就能看到类型
//   - `SyncLLMProviderAdapter` — 把 AsyncLLMProvider 装成 Brain.LLMProvider（用 semaphore
//                          桥接 sync → async），从而能塞进 Brain.respond()
//   - `AsyncLLMProviderAdapter` — 反向，把 Brain.LLMProvider（MockLLM）装成 AsyncLLMProvider，
//                          给 main entry 的 fixture fallback 用
//
// 三方约束（frozen Brain 不动）：
//   - 真 provider **永远**走 async 路径
//   - Brain.respond(to:) 是 sync，所以 demo 路径走 SyncLLMProviderAdapter
//   - 集成测试用 MockLLM（sync LLMProvider），不经过 adapter
//
// 不做：
//   - 改 PetProfileBrain.LLMProvider 任何字段
//   - 在 protocol extension 里加 async 调 sync 的 default impl（会 infinite recurse
//     或者 dispatch 不通，详见 https://forums.swift.org/t/...)
//

import Foundation
@preconcurrency import PetProfileBrain

// MARK: - Re-export

/// 跟 `PetProfileBrain.LLMProvider` 同名 alias。caller 只 import PetProfileLLM
/// 就能用 `LLMProvider` 类型（避免同时 import 3 个 module）。
public typealias LLMProvider = PetProfileBrain.LLMProvider

// MARK: - AsyncLLMProvider

/// 异步 LLM 协议 — 给真 provider（OpenAI / Claude / local）用。
///
/// 跟 Brain.LLMProvider 的关键差异：
///   - 异步：URLSession data(for:) 是 async 的
///   - `name: String` 唯一标识（"openai" / "claude" / "openai-compatible:<endpoint>"）
///   - 抛 LLMError（5 类 transport / 状态码错误）
///
/// 实现要求：
///   - 必须实现 async `complete(prompt:)`
///   - 不允许抛 Brain.LLMError（那属于"已解析"层的错误，不是 transport 层）
///   - 不允许缓存响应（违反 fresh-生成原则；AGENTS.md "Local-First And BYOK"）
///
/// Sendable 选择：协议**不**强制 Sendable，因为 MockLLM / 老的 sync LLMProvider impl
/// 不一定是 Sendable。AsyncLLMProvider 的真实现（OpenAIProvider 等）通常是 Sendable
/// struct，可自行加 conformance；本协议不强制。
public protocol AsyncLLMProvider {
    /// 唯一标识（"openai" / "claude" / "openai-compatible:..." / 任何自定义）
    var name: String { get }

    /// 异步调 LLM，返回原始 response text（不解析）。
    /// - Throws: LLMError（networkError / unauthorized / rateLimited / serverError /
    ///   timeout / invalidResponse）
    func complete(prompt: String) async throws -> String
}

// MARK: - SyncLLMProviderAdapter

/// 把 `AsyncLLMProvider` 装成 `PetProfileBrain.LLMProvider`（同步）。
///
/// 内部用 `DispatchSemaphore` 桥接：调同步方法 → spawn async task → 等结果。
///
/// 用法：
/// ```swift
/// let real: AsyncLLMProvider = OpenAIProvider(apiKey: "...")
/// let sync = SyncLLMProviderAdapter(wrapping: real)
/// let brain = Brain(profile: p, llm: sync, dispatcher: d)
/// let resp = try brain.respond(to: "hi")
/// ```
///
/// **不要**在 main thread 上跑这个 adapter 的 complete（会死锁）：
///   - semaphore 在调用线程上 wait
///   - async task 内部如果用 `URLSession.shared.data(for:)` 走默认 delegate queue，
///     delegate callback 不回到 main thread → 不会死锁
///   - 但如果实现方把 async 任务 dispatch 到 main queue → 死锁
///
/// 实现方约束：complete() 的 async task 不能 dispatch 到调用线程。
public final class SyncLLMProviderAdapter: LLMProvider, @unchecked Sendable {

    private let async: AsyncLLMProvider
    public var name: String { async.name }

    public init(wrapping async: AsyncLLMProvider) {
        self.async = async
    }

    public func complete(prompt: String) throws -> String {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox()
        let innerAsync = async
        Task.detached(priority: .userInitiated) {
            do {
                let result = try await innerAsync.complete(prompt: prompt)
                box.set(.success(result))
            } catch {
                box.set(.failure(error))
            }
            sem.signal()
        }
        sem.wait()
        return try box.unwrap()
    }
}

// MARK: - AsyncLLMProviderAdapter (反向)

/// 把同步的 `LLMProvider`（如 PetProfileBrain.MockLLM）装成 `AsyncLLMProvider`。
///
/// 用途：fixture 模式下，main entry / 异步 caller 想用 MockLLM 但又要 async 接口。
public final class AsyncLLMProviderAdapter: AsyncLLMProvider {
    private let sync: LLMProvider
    public var name: String { sync.name ?? "unknown" }

    public init(wrapping sync: LLMProvider) {
        self.sync = sync
    }

    public func complete(prompt: String) async throws -> String {
        // MockLLM 是 sync-`throws`，把它包成 async-throws
        return try await Task.detached(priority: .userInitiated) { [sync] in
            try sync.complete(prompt: prompt)
        }.value
    }
}

// MARK: - name 扩展（给 sync LLMProvider）

/// Brain.LLMProvider 是 frozen 的，没声明 name。我们给个 default implementation extension，
/// 让所有"不知道 name"的 sync LLMProvider 都能通过 SyncLLMProviderAdapter / AsyncLLMProviderAdapter
/// 拿到一个 fallback name。
///
/// **不**给 PetProfileBrain.LLMProvider 加 `name` requirement（那就改了 frozen 协议）。
/// 改用 type-name fallback（PetProfileBrain.MockLLM → "mock"，自定义 impl → type 名字）。
public extension PetProfileBrain.LLMProvider {
    /// 默认用 type name 作 name。要求 conformance 显式覆盖（OpenAIProvider / ClaudeProvider 都有
    /// 自己的 `let name`），或者用协议 extension 覆盖。
    var name: String? {
        return String(describing: type(of: self))
    }
}

// MARK: - ResultBox（线程安全）

/// 极小的 result 容器：semaphore.wait() 时跨线程安全。
private final class ResultBox: @unchecked Sendable {
    private var value: Result<String, Error>?
    private let lock = NSLock()

    func set(_ r: Result<String, Error>) {
        lock.lock()
        defer { lock.unlock() }
        value = r
    }

    func unwrap() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let v = value else {
            throw LLMError.invalidResponse(reason: "SyncLLMProviderAdapter: no result captured")
        }
        return try v.get()
    }
}

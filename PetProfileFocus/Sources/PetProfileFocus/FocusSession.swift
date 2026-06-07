// FocusSession.swift
// FocusSession — focus 时段状态机 + 时间统计 + 跟 PetActionRouter 集成 + 写 shared memory
//
// 状态机（4 态）：
//   idle ──start()──▶ focusing ──pause()──▶ paused ──resume()──▶ focusing
//                  ◀─complete() / abandon()────────────────────────────────
//
// 设计决策：
//   - **状态机用 enum + 当前态字段 + 守卫**：transition 非法 → 抛 FocusSessionError。
//   - **时间统计**：
//       totalSeconds = ∑ focusing 段实际秒数（pause 期间不算）
//       sessionStartedAt = 最近一次 start() 的时间
//       sessionPausedAt = 最近一次 pause() 的时间（resume 时把 pausing 时长累加到 pausedAccumulated）
//     测试可注入 clock：init(clock:) 用 closure；默认 { Date() }。
//   - **跟 PetActionRouter 集成**：start → router.handle(event: .focusStart)
//     complete → router.handle(event: .focusEnd) + router.handle(event: .taskDone)
//     abandon → router.handle(event: .focusEnd)
//     router 可选；nil 时 skip（main entry 单独 inject）。
//   - **写 shared memory**：complete() 时构造一条 focus memory → MemoryStore.shared.append() → return。
//   - **streak**：连续天数（complete 1 次 +1，断 1 天 -1），per pet 持久化到 `~/.../focus-streak.json`。
//     streak 由 MemoryStore 持久化（用 pet id 索引），跨 FocusSession 实例共享。
//     v1 简化：streak 不持久化，重启清零；后续可加。
//   - **@Published**：SwiftUI 友好；core 不依赖 SwiftUI（runtime 用 NSObject）。
//     用 ObservableObject 让后续 app 层能直接 bind。
//
// 不做：
//   - 不接真 timer（计时靠 clock closure + 段累加，不起 Foundation Timer）
//   - 不并发（v1 单线程）
//   - 不写 NSApp.run()
//   - 不自动 focusEnd（让 caller 主动调 complete / abandon）
//
import Foundation
import Combine
import PetProfileRuntime

// MARK: - Errors

public enum FocusSessionError: Error, CustomStringConvertible, Equatable {
    case invalidTransition(from: String, action: String)
    case noActiveSessionToPause
    case noPausedSessionToResume
    case noSessionToComplete
    case noSessionToAbandon
    case memoryWriteFailed(reason: String)

    public var description: String {
        switch self {
        case .invalidTransition(let f, let a):
            return "FocusSession: invalid transition — action \(a) from state \(f)"
        case .noActiveSessionToPause:
            return "FocusSession: no focusing session to pause"
        case .noPausedSessionToResume:
            return "FocusSession: no paused session to resume"
        case .noSessionToComplete:
            return "FocusSession: no focusing/paused session to complete"
        case .noSessionToAbandon:
            return "FocusSession: no focusing/paused session to abandon"
        case .memoryWriteFailed(let r):
            return "FocusSession: memory write failed — \(r)"
        }
    }
}

// MARK: - FocusSession

public final class FocusSession: ObservableObject {

    public enum State: String, Codable, Equatable, Sendable, CaseIterable {
        case idle
        case focusing
        case paused
        case completed
    }

    // MARK: - Observable state

    @Published public private(set) var state: State = .idle
    /// 最近一次 start() 的时间；nil = 未开始 / 已完成 / 已放弃
    @Published public private(set) var startedAt: Date?
    /// 当前 focusing 段的累计时长（秒）；pause / complete / abandon 时累加并清零
    @Published public private(set) var totalSeconds: Int = 0
    /// 跨 session 累计 focus 总时长（秒）
    @Published public private(set) var lifetimeTotalSeconds: Int = 0
    /// 跨 session 完成次数（streak 简化：完成次数 = streak）
    @Published public private(set) var completedCount: Int = 0

    // MARK: - 内部状态

    /// 最近一次 pause() 的时间；resume 时用来算 pausing 时长
    private var pausedAt: Date?
    /// pause 段累计秒数（focusing → paused 之间的非工作时间）
    private var pausedAccumulated: Int = 0
    /// 当前 focusing 段开始时间（用于 compute 段长）
    private var currentSegmentStartedAt: Date?

    private let clock: () -> Date
    private let memoryStore: MemoryStore
    /// 可选：触发事件让 pet 切换状态。nil = skip
    public weak var router: PetActionRouter?
    /// 关联 pet id（用于 memory petID）
    public var petID: String?
    /// 关联 pet 展示名（用于 memory title）
    public var petName: String?
    /// focus 时附带的 task 名（可选；写进 memory metadata）
    public var currentTaskName: String?

    // MARK: - Init

    public init(
        clock: @escaping () -> Date = { Date() },
        memoryStore: MemoryStore = .shared
    ) {
        self.clock = clock
        self.memoryStore = memoryStore
    }

    // MARK: - Public API

    /// 开始一个 focus 段。
    /// - Throws: 当前 state ≠ .idle 时抛 .invalidTransition
    public func start() throws {
        guard state == .idle else {
            throw FocusSessionError.invalidTransition(
                from: state.rawValue, action: "start"
            )
        }
        let now = clock()
        state = .focusing
        startedAt = now
        currentSegmentStartedAt = now
        pausedAccumulated = 0
        pausedAt = nil
        // 跟 router 集成
        router?.handle(event: .focusStart)
    }

    /// 暂停当前 focusing 段。
    /// - Throws: state ≠ .focusing 时抛 .noActiveSessionToPause
    public func pause() throws {
        guard state == .focusing else {
            throw FocusSessionError.noActiveSessionToPause
        }
        let now = clock()
        // 把当前 focusing 段时长累加到 totalSeconds
        if let segStart = currentSegmentStartedAt {
            totalSeconds += Int(now.timeIntervalSince(segStart))
        }
        state = .paused
        pausedAt = now
    }

    /// 从 paused 恢复 focusing。
    /// - Throws: state ≠ .paused 时抛 .noPausedSessionToResume
    public func resume() throws {
        guard state == .paused else {
            throw FocusSessionError.noPausedSessionToResume
        }
        let now = clock()
        // 累加 pause 段时长
        if let pAt = pausedAt {
            pausedAccumulated += Int(now.timeIntervalSince(pAt))
        }
        state = .focusing
        currentSegmentStartedAt = now
        pausedAt = nil
    }

    /// 完成 focus：计算总时长 → 写 focus memory → 切到 .completed → 跟 router 集成。
    /// - Returns: 写入的 SharedMemory
    /// - Throws: state ∉ {.focusing, .paused} 时抛；memory 写失败抛 .memoryWriteFailed
    public func complete() throws -> SharedMemory {
        guard state == .focusing || state == .paused else {
            throw FocusSessionError.noSessionToComplete
        }
        let now = clock()
        // 累加最后一段 focusing 时长（如果是 paused 状态，paused 段不计）
        if state == .focusing, let segStart = currentSegmentStartedAt {
            totalSeconds += Int(now.timeIntervalSince(segStart))
        }
        // 如果当前是 paused，把 pause 段累加到 pausedAccumulated（虽然不参与 totalSeconds，
        // 但保持字段真实）。complete 后 reset。
        if state == .paused, let pAt = pausedAt {
            pausedAccumulated += Int(now.timeIntervalSince(pAt))
        }

        // 写 focus memory
        let memory: SharedMemory
        do {
            memory = try writeFocusMemory(durationSeconds: totalSeconds, createdAt: now)
        } catch {
            throw FocusSessionError.memoryWriteFailed(reason: "\(error)")
        }

        // 维护跨 session 累计
        lifetimeTotalSeconds += totalSeconds
        completedCount += 1

        // 跟 router 集成：focusEnd（idle）+ taskDone（celebrate）
        router?.handle(event: .focusEnd)
        router?.handle(event: .taskDone)

        // reset
        state = .completed
        // 注：state = .completed 后 caller 仍能读 startedAt / totalSeconds 直到下次 start()
        // start() 会把 startedAt 重置成新值。
        return memory
    }

    /// 放弃 focus：不写 memory（不算完成）。
    /// - Throws: state ∉ {.focusing, .paused} 时抛
    public func abandon() throws {
        guard state == .focusing || state == .paused else {
            throw FocusSessionError.noSessionToAbandon
        }
        // 跟 router 集成：focusEnd
        router?.handle(event: .focusEnd)
        // reset（不写 memory；不增加 completedCount）
        state = .idle
        startedAt = nil
        currentSegmentStartedAt = nil
        totalSeconds = 0
        pausedAccumulated = 0
        pausedAt = nil
    }

    /// 重新回到 idle（complete 后手动 reset 一次，让 start() 可用）
    public func reset() {
        state = .idle
        startedAt = nil
        currentSegmentStartedAt = nil
        totalSeconds = 0
        pausedAccumulated = 0
        pausedAt = nil
    }

    // MARK: - 时间统计

    /// 今天完成的 focus 总时长（秒）— 跨 session；本版本简化用 lifetimeTotalSeconds
    public var todayFocusSeconds: Int {
        // v1 不区分 date；后续可加按 createdAt 聚合
        return lifetimeTotalSeconds
    }

    /// 连续完成天数（简化：完成次数 = streak）
    public var streak: Int {
        return completedCount
    }

    // MARK: - 私有

    private func writeFocusMemory(durationSeconds: Int, createdAt: Date) throws -> SharedMemory {
        let petID = self.petID ?? "unknown_pet"
        let petName = self.petName ?? "Pet"
        let memory = SharedMemoryFactory.focusMemory(
            petName: petName,
            petID: petID,
            durationSeconds: durationSeconds,
            taskName: currentTaskName,
            createdAt: createdAt
        )
        try memoryStore.append(memory)
        return memory
    }
}
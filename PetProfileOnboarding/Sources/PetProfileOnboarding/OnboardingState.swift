// OnboardingState.swift
// OnboardingState — Codable + 持久化到 ~/Library/Application Support/oh-my-pet/onboarding-state.json
//
// 设计决策：
//   - 状态文件路径 = FileManager 解析 ~/Library/Application Support/oh-my-pet/onboarding-state.json
//     （macOS 平台官方推荐位置；AGENTS.md "Local-First And BYOK" 一致）
//   - JSONEncoder/Decoder: prettyPrinted + sortedKeys + ISO8601 date
//     （跟 PetProfileKit.ProfileIO 风格保持一致；diff 友好）
//   - save() 失败抛错（不静默吞 — UI 决定怎么提示）
//   - load() 区分 notFound / corrupted：
//     - notFound → 抛 .stateFileNotFound（让 caller 决定是否从 Stage 1 开始）
//     - corrupted → 抛 .stateFileCorrupted（让 caller 走 reset）
//   - 失败恢复测试要求：corrupted 文件 → reset() → 从 Stage 1 开始
//   - 字段名全部 snake_case（持久化兼容 PetProfileKit 风格）
//   - **不**直接持有 PetProfileV1 引用 —— onboarding state 跟具体 profile 解耦
//     （pet profile 由 Pet House 单独管理；onboarding 只记"用户选了什么路径 + 声音风格名"）
//
// 不做：
//   - 不存真实 API key（byokKeychainRef 只存 Keychain 引用 key 字符串）
//   - 不存真实音频样本（VoiceCloneConsent.sampleFilename 只存文件名，文件由用户本地管）
//   - 不存当前 active profile（onboarding 结束后，Pet House / Runtime 自己 load manifest）
//

import Foundation

// MARK: - OnboardingState

public struct OnboardingState: Codable, Equatable, Sendable {
    /// 当前所在 stage
    public var currentStage: OnboardingStage
    /// 用户在 Stage 1 选的路径（welcome 阶段 = nil）
    public var chosenPath: OnboardingPath?
    /// pet profile 路径（Stage 2 完成后存；C 路径在 Stage 1 选完就存；D 路径在 Stage 1 选完 sample 后存）
    public var petProfilePath: URL?
    /// voice style 名（如 "warm-gentle" / "cold-sarcastic" / "drawl-deadpan"）— 跟 PetProfile 5 pet 的 voiceStyle.tone 对齐
    public var voiceStyle: String?
    /// 是否走了 voice clone（决定 profile.audio.voiceCloneConsent 是否为 nil）
    public var voiceCloned: Bool
    /// voice clone 显式 consent（红线 — Stage 3 强校验）
    public var voiceCloneConsent: VoiceCloneConsent?
    /// BYOK provider 名（如 "openai" / "anthropic" / "default"）— 默认 = nil（未走 BYOK）
    public var byokProvider: String?
    /// Keychain 引用 key（真实 API key 在 Keychain 里；这里只存引用 key 字符串）
    public var byokKeychainRef: String?
    /// 首次 launch 时刻（Stage 4 完成时打时间戳）
    public var launchTime: Date?

    public init(
        currentStage: OnboardingStage = .welcome,
        chosenPath: OnboardingPath? = nil,
        petProfilePath: URL? = nil,
        voiceStyle: String? = nil,
        voiceCloned: Bool = false,
        voiceCloneConsent: VoiceCloneConsent? = nil,
        byokProvider: String? = nil,
        byokKeychainRef: String? = nil,
        launchTime: Date? = nil
    ) {
        self.currentStage = currentStage
        self.chosenPath = chosenPath
        self.petProfilePath = petProfilePath
        self.voiceStyle = voiceStyle
        self.voiceCloned = voiceCloned
        self.voiceCloneConsent = voiceCloneConsent
        self.byokProvider = byokProvider
        self.byokKeychainRef = byokKeychainRef
        self.launchTime = launchTime
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case currentStage = "current_stage"
        case chosenPath = "chosen_path"
        case petProfilePath = "pet_profile_path"
        case voiceStyle = "voice_style"
        case voiceCloned = "voice_cloned"
        case voiceCloneConsent = "voice_clone_consent"
        case byokProvider = "byok_provider"
        case byokKeychainRef = "byok_keychain_ref"
        case launchTime = "launch_time"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.currentStage = try c.decode(OnboardingStage.self, forKey: .currentStage)
        self.chosenPath = try c.decodeIfPresent(OnboardingPath.self, forKey: .chosenPath)
        self.petProfilePath = try c.decodeIfPresent(URL.self, forKey: .petProfilePath)
        self.voiceStyle = try c.decodeIfPresent(String.self, forKey: .voiceStyle)
        self.voiceCloned = try c.decodeIfPresent(Bool.self, forKey: .voiceCloned) ?? false
        self.voiceCloneConsent = try c.decodeIfPresent(VoiceCloneConsent.self, forKey: .voiceCloneConsent)
        self.byokProvider = try c.decodeIfPresent(String.self, forKey: .byokProvider)
        self.byokKeychainRef = try c.decodeIfPresent(String.self, forKey: .byokKeychainRef)
        self.launchTime = try c.decodeIfPresent(Date.self, forKey: .launchTime)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(currentStage, forKey: .currentStage)
        try c.encodeIfPresent(chosenPath, forKey: .chosenPath)
        try c.encodeIfPresent(petProfilePath, forKey: .petProfilePath)
        try c.encodeIfPresent(voiceStyle, forKey: .voiceStyle)
        try c.encode(voiceCloned, forKey: .voiceCloned)
        try c.encodeIfPresent(voiceCloneConsent, forKey: .voiceCloneConsent)
        try c.encodeIfPresent(byokProvider, forKey: .byokProvider)
        try c.encodeIfPresent(byokKeychainRef, forKey: .byokKeychainRef)
        try c.encodeIfPresent(launchTime, forKey: .launchTime)
    }
}

// MARK: - Persistence

public enum OnboardingStateStore {
    /// 默认状态文件路径：~/Library/Application Support/oh-my-pet/onboarding-state.json
    /// macOS 平台官方推荐位置。
    public static func defaultURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let appDir = appSupport.appendingPathComponent("oh-my-pet", isDirectory: true)
        // 确保目录存在
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir.appendingPathComponent("onboarding-state.json")
    }

    /// 注入式 URL（测试用 — 用临时目录避免污染真 ~/Library）
    public static func url(in directory: URL) -> URL {
        return directory.appendingPathComponent("onboarding-state.json")
    }

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // 用 timeIntervalSince1970 作为 Double 编码：保留 Date 的全 Double 精度，
        // 避免 ISO8601 / millisecondsSince1970 截断导致 roundtrip 后 `==` 失败。
        // JSON 里就是 `"launchTime": 1782674812.345678` 这种数字，debug 友好。
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(date.timeIntervalSince1970)
        }
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let interval = try c.decode(Double.self)
            return Date(timeIntervalSince1970: interval)
        }
        return d
    }()
}

// MARK: - OnboardingState save/load

extension OnboardingState {
    /// 写盘（默认路径）。失败抛 OnboardingError.persistenceWriteFailed。
    public mutating func save() throws {
        let url = try OnboardingStateStore.defaultURL()
        try save(to: url)
    }

    /// 写盘（注入 URL — 测试用）。失败抛 OnboardingError.persistenceWriteFailed。
    public mutating func save(to url: URL) throws {
        do {
            let data = try OnboardingStateStore.encoder.encode(self)
            // 原子写：先写 .tmp 再 rename，避免中途崩坏留半截
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            throw OnboardingError.persistenceWriteFailed(reason: error.localizedDescription)
        }
    }

    /// 读盘（默认路径）。
    /// - 不存在 → 抛 .stateFileNotFound
    /// - 存在但损坏 → 抛 .stateFileCorrupted
    public static func load() throws -> OnboardingState {
        let url = try OnboardingStateStore.defaultURL()
        return try load(from: url)
    }

    /// 读盘（注入 URL — 测试用）。
    public static func load(from url: URL) throws -> OnboardingState {
        if !FileManager.default.fileExists(atPath: url.path) {
            throw OnboardingError.stateFileNotFound
        }
        do {
            let data = try Data(contentsOf: url)
            return try OnboardingStateStore.decoder.decode(OnboardingState.self, from: data)
        } catch let err as OnboardingError {
            throw err
        } catch {
            throw OnboardingError.stateFileCorrupted(reason: error.localizedDescription)
        }
    }

    /// 删除状态文件（reset 时调；不抛错 — 文件不存在视为 ok）
    public static func delete() throws {
        let url = try OnboardingStateStore.defaultURL()
        try delete(at: url)
    }

    public static func delete(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                throw OnboardingError.persistenceWriteFailed(reason: "delete failed: \(error.localizedDescription)")
            }
        }
    }

    /// reset —— 删除文件 + 返回 fresh 状态
    public static func reset() throws -> OnboardingState {
        try delete()
        return OnboardingState()
    }

    /// reset —— 注入 URL（测试用 — 不污染真 ~/Library）
    public static func reset(to url: URL) throws -> OnboardingState {
        try delete(at: url)
        return OnboardingState()
    }
}

// ImageValidationError.swift
// 校验 / provider 错误类型 — 区分上传校验失败 vs AI provider 异常
//
// 错误分层（spec §3.1）：
//   - ImageValidationError：上传 / 落盘前的校验失败（含哪个 state + 哪个 check + 原因）
//   - ImageProviderError：provider 自身异常（不实现 / 缺 key / IO 错 / API 错）
//
// 两条错误链**不**重合：
//   - 上传校验失败 → ImageValidationError（用户该改文件）
//   - AI provider 不可用 / 网络 / 凭据 → ImageProviderError（用户该检查 key / 网络）
//
// 设计要点：
//   - ImageValidationError 同时携带 state 信息（哪个 state）+ check 信息（哪个校验项）
//   - ImageProviderError 用统一 .notImplemented 让 AI stub 测试能稳定断言
//   - 都 conform Equatable + CustomStringConvertible（test / 日志友好）
//

import Foundation
import PetProfileRuntime

// MARK: - ImageValidationError

/// 上传 / 校验阶段失败。
/// 失败位置 = `state`（哪个 state 的图）+ `check`（哪个校验项）。
public struct ImageValidationError: Error, CustomStringConvertible, Equatable {
    /// 失败的 state（可选 —— 整个 request 层面失败时为 nil）
    public let state: VisualState?
    /// 失败的校验项
    public let check: Check
    /// 人类可读原因
    public let message: String

    public enum Check: String, Codable, Equatable, Sendable {
        /// 文件数量不是 5
        case countMismatch
        /// 文件不存在
        case missingFile
        /// 不是 PNG（magic bytes 不匹配）
        case notPNG
        /// 不含 alpha channel（spec 要求 transparent）
        case noAlphaChannel
        /// 5 张图尺寸不一致
        case sizeMismatch
        /// 单张文件 > 5 MB
        case fileTooLarge
        /// 文件可读但图像 decode 失败（损坏 PNG）
        case decodeFailed
        /// 落盘阶段 IO 错误
        case writeFailed
    }

    public init(state: VisualState? = nil, check: Check, message: String) {
        self.state = state
        self.check = check
        self.message = message
    }

    public var description: String {
        if let s = state {
            return "ImageValidationError(state=\(s.rawValue), check=\(check.rawValue): \(message)"
        }
        return "ImageValidationError(check=\(check.rawValue)): \(message)"
    }
}

// MARK: - ImageProviderError

/// ImageProvider 调用层异常。
/// 区分 stub（notImplemented）/ 缺凭据（keyMissing）/ API 错误（networkError / apiError 等）。
public enum ImageProviderError: Error, CustomStringConvertible, Equatable {
    /// Provider 未实现（如 AI stub 阶段）
    case notImplemented(providerID: String, message: String)
    /// 需要 API key 但 Keychain 找不到
    case keyMissing(providerID: String)
    /// Provider 自身 IO 错误（落盘失败等）
    case ioError(providerID: String, reason: String)
    /// 网络错误（AI provider；stub 不走这里）
    case networkError(providerID: String, reason: String)
    /// API 返回错（rate limited / content refused / 等）
    case apiError(providerID: String, reason: String)

    public var description: String {
        switch self {
        case .notImplemented(let id, let m):
            return "ImageProviderError: provider \(id) not implemented — \(m)"
        case .keyMissing(let id):
            return "ImageProviderError: provider \(id) requires API key but none found in Keychain"
        case .ioError(let id, let r):
            return "ImageProviderError: provider \(id) IO error — \(r)"
        case .networkError(let id, let r):
            return "ImageProviderError: provider \(id) network error — \(r)"
        case .apiError(let id, let r):
            return "ImageProviderError: provider \(id) API error — \(r)"
        }
    }
}

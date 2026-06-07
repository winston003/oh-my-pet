// ImageProvider.swift
// ImageProvider — 视觉资产生成协议 + 协议数据类型
//
// 协议层对应平台不变量 spec §3.1 Provider 三元组中的 ImageProvider：
//   - 文生图 / 图生图 / state 重生成（这里只规定数据契约，不规定算法）
//   - 实际实现可以是 UploadImageProvider（默认，本地文件）
//   - 也可以是 AI 生成 provider（OpenAI DALL-E / Stable Diffusion）—— 这些是 stub，
//     留协议钩子，UI 在用户配了 provider key 之后才显示
//
// 设计要点：
//   - PetState 用 PetProfileRuntime.VisualState（frozen 5 枚举；与 schema 同步）
//   - ImageGenerationRequest 中 uploadURLs 顺序对应 5 个 state
//     （state[i] 对应 uploadURLs[i]，调用方负责顺序）
//   - ImageGenerationResult.states 用 [PetState: URL]（dictionary；5 个 key）
//   - 所有类型 Sendable + Codable，便于跨 actor / 跨模块传
//
// 不做：
//   - 不接真 OpenAI / SD / Replicate API（属 stub 阶段）
//   - 不实现 streaming / partial progress（ImageGenerationRequest → Result 是单次）
//   - 不引入第三方 SDK（spec §3.1 禁止 import 具体 provider）
//

import Foundation
import PetProfileRuntime

// MARK: - ImageProvider protocol

/// 视觉资产生成 provider 协议。注册到 ImageProviderRegistry，
/// UI 通过 registry 列出所有可用 provider，调用方不直接 import 具体 SDK。
public protocol ImageProvider: Sendable {
    /// Provider 唯一标识（如 "upload-local" / "openai-dalle" / "stable-diffusion"）
    var id: String { get }

    /// UI 显示名（如 "本地上传" / "OpenAI DALL-E"）
    var displayName: String { get }

    /// 是否需要 API key（Keychain 凭据）
    ///   - true: UI 需先检测 Keychain 是否有 key，没有就 disable 该 provider
    ///   - false: 无凭据依赖（如 upload）
    var requiresAPIKey: Bool { get }

    /// 给定 prompt / 参考图 / 上传文件，生成 image data + metadata。
    /// - upload provider：消费 request.uploadURLs（5 个 state → 5 个 URL）
    /// - AI provider（stub）：抛 ImageProviderError.notImplemented（不调真网络）
    /// - Throws: ImageProviderError（不实现 / 缺 key / 校验失败 / IO 错误 / API 错）
    func generate(request: ImageGenerationRequest) async throws -> ImageGenerationResult
}

// MARK: - Request / Result 数据契约

/// ImageProvider.generate 输入。
/// - petID: 标识目标 pet（provider 用于落盘路径）
/// - states: 5 个 state（顺序对应 uploadURLs 顺序；缺省不强制但建议对齐）
/// - prompt: 文本 prompt（upload provider 忽略；AI provider 用）
/// - referenceImageURLs: 可选参考图（upload provider 忽略；AI provider 用）
/// - uploadURLs: 用户从 NSOpenPanel 选定的本地文件 URL（5 个 state）；
///   upload provider **只**消费这 5 个 URL，不调任何 AI API。
public struct ImageGenerationRequest: Codable, Sendable, Equatable {
    public let petID: String
    public let states: [VisualState]
    public let prompt: String?
    public let referenceImageURLs: [URL]
    public let uploadURLs: [URL]

    public init(
        petID: String,
        states: [VisualState],
        prompt: String? = nil,
        referenceImageURLs: [URL] = [],
        uploadURLs: [URL] = []
    ) {
        self.petID = petID
        self.states = states
        self.prompt = prompt
        self.referenceImageURLs = referenceImageURLs
        self.uploadURLs = uploadURLs
    }
}

/// ImageProvider.generate 输出。
/// - providerID: 调用方实际用的 provider（用于 generation history / debug）
/// - states: 5 个 state → 落盘后的本地 file URL（绝对路径）
/// - generatedAt: 生成时间
/// - metadata: provider 自由填的键值对（如 "model" / "seed" / "upload_source_size" 等）
public struct ImageGenerationResult: Codable, Sendable, Equatable {
    public let providerID: String
    public let states: [VisualState: URL]
    public let generatedAt: Date
    public let metadata: [String: String]

    public init(
        providerID: String,
        states: [VisualState: URL],
        generatedAt: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.providerID = providerID
        self.states = states
        self.generatedAt = generatedAt
        self.metadata = metadata
    }
}

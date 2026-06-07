// StableDiffusionImageProvider.swift
// StableDiffusionImageProvider — AI provider **stub**（同上 OpenAIDALLEImageProvider）
//
// 行为：register 进 ImageProviderRegistry；generate() 抛 notImplemented。
//       真实接入路径与 OpenAIDALLE 相同（URLSession 调 API + Keychain 读 key + UI 透明）。
//
// 模型选择空间（未来真接入时，UI 应让用户选）：
//   - Stable Diffusion XL（Stability AI / Replicate / 自部署）
//   - SD 3.5 / Flux（社区版）
//   - 本地 SD（comfyui / A1111 / mflux）—— macOS 优先
//
// 当前阶段不接，留协议钩子。
//

import Foundation
import PetProfileRuntime

public final class StableDiffusionImageProvider: ImageProvider, @unchecked Sendable {
    public static let providerID: String = "stable-diffusion"

    public let id: String = StableDiffusionImageProvider.providerID
    public let displayName: String = "Stable Diffusion"
    public let requiresAPIKey: Bool = true

    public init() {}

    public func generate(request: ImageGenerationRequest) async throws -> ImageGenerationResult {
        // 显式 notImplemented —— 不调真网络
        throw ImageProviderError.notImplemented(
            providerID: id,
            message: "AI 生成暂未接入，请使用本地上传"
        )
    }
}

// OpenAIDALLEImageProvider.swift
// OpenAIDALLEImageProvider — AI provider **stub**。
//
// 当前阶段不接真 OpenAI API（owner 拍板：MVP 走 upload；AI provider 留协议钩子）。
// 行为：register 进 ImageProviderRegistry，UI 能列出 provider；
//       generate() 抛 ImageProviderError.notImplemented + 友好中文 message。
//
// 为什么 stub 也要写：
//   - spec §3.1 "内置至少 1 个 Stub*Provider，保证无网、无 key 时 UI 可跑通"
//   - UI 可在用户配了 Keychain key 之后才 enable 该选项（这部分 UI 暂未实现；
//     当前直接列在所有 provider 列表里，UI 上 call site 决定怎么 disable）
//
// 升级路径（未来 owner 决定接入真 API 时）：
//   1. 替换 generate() 实现：用 URLSession 调 OpenAI /v1/images/generations
//   2. Keychain 读 key（service = "com.oh-my-pet.providers", account = "openai"）
//   3. UI 必须展示 provider id / model / 数据类型 / 发送内容（spec §3.1 不变量）
//   4. 真网络调用的测试**用 URLProtocol mock 验证 0 真实请求**
//   5. 真实集成测试放 in-house key 环境（不入 CI）
//

import Foundation
import PetProfileRuntime

public final class OpenAIDALLEImageProvider: ImageProvider, @unchecked Sendable {
    public static let providerID: String = "openai-dalle"

    public let id: String = OpenAIDALLEImageProvider.providerID
    public let displayName: String = "OpenAI DALL-E"
    public let requiresAPIKey: Bool = true

    public init() {}

    public func generate(request: ImageGenerationRequest) async throws -> ImageGenerationResult {
        // 显式 notImplemented —— 不调真网络（spec 要求无网 / 无 key 也能跑通 UI）
        throw ImageProviderError.notImplemented(
            providerID: id,
            message: "AI 生成暂未接入，请使用本地上传"
        )
    }
}

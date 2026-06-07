// Loader.swift
// PetProfile v1 加载器
//
// 责任：
//   1. 用 PetProfileKit 的 ProfileIO.decodeV1 解析 manifest
//   2. 用 PetProfileKit 的 Validator 跑严格校验
//   3. 把相对 asset 路径解析为绝对 URL（基于 profile root）
//   4. 给缺失的 asset 文件生成占位 PNG（避免运行时崩，但不引入真美术资产）
//   5. 返回一个 decoupled 的 LoadedPetProfile（runtime 不直接持有 PetProfileV1）
//
// 设计决策：
//   - Loader 是 struct（无状态、可拷贝）
//   - 不持有 NSApplication / NSWindow，纯 Foundation
//   - LoadedPetProfile 是 Sendable 的（值类型 + Foundation 类型）
//   - 占位 PNG：64x64 透明背景 + 圆角矩形 + 宠物名首字符，用 Core Graphics 画
//     一次写盘后下次直接复用；保证同 profileRoot 下 idempotent
//
// 不做：
//   - 资源热加载（v1 只支持一次性 load）
//   - v0.1.0 升级路径（用 PetProfileKit.Upgrader 单独走）
//   - 远程 URL 拉取（asset 路径必须 relative，不允许 http(s)://）

import Foundation
import AppKit
import PetProfile

// MARK: - LoadedPetProfile (runtime-facing data struct)

/// 加载后的 PetProfile 快照。runtime 层用这个，不要直接拿 PetProfileV1。
/// decoupled 是有意的：将来如果 PetProfileKit 升级 (v1.1 / v2)，runtime API 形状不变。
public struct LoadedPetProfile: Equatable, Sendable {
    /// profile root 目录（manifest 所在目录），asset 路径相对它解析
    public let profileRoot: URL
    /// 顶层 manifest snapshot
    public let manifest: PetProfileV1
    /// 解析后的 visual 通道 asset URL 字典（key = 5 state 名）
    public let visualAssetURLs: [String: URL]
    /// 解析后的 expression 通道 asset URL 字典（key = state 名 或 extended name）
    public let expressionAssetURLs: [String: URL]
    /// action.idle 的 asset URL（可选，schema 允许为空）
    public let actionIdleAssetURL: URL?
    /// action.reactions 的 asset URL 数组（index 对齐 reactions，nil 表示没指定）
    public let actionReactionAssetURLs: [URL?]
    /// voice_clone_consent.sample_path 解析后的 URL（可能 nil）
    public let voiceCloneSampleURL: URL?

    public init(
        profileRoot: URL,
        manifest: PetProfileV1,
        visualAssetURLs: [String: URL],
        expressionAssetURLs: [String: URL],
        actionIdleAssetURL: URL?,
        actionReactionAssetURLs: [URL?],
        voiceCloneSampleURL: URL?
    ) {
        self.profileRoot = profileRoot
        self.manifest = manifest
        self.visualAssetURLs = visualAssetURLs
        self.expressionAssetURLs = expressionAssetURLs
        self.actionIdleAssetURL = actionIdleAssetURL
        self.actionReactionAssetURLs = actionReactionAssetURLs
        self.voiceCloneSampleURL = voiceCloneSampleURL
    }
}

// MARK: - Loader

public struct PetProfileLoader {
    public init() {}

    /// 从 manifest URL 加载 v1 profile。
    /// - Parameter manifestURL: 指向 `*.json` 的 file URL（v1 manifest）
    /// - Throws: `LoaderError` 或 `ValidationError` 或 `ProfileIO` 抛出的 DecodingError
    public func loadProfile(from manifestURL: URL) throws -> LoadedPetProfile {
        // 1. 解析 + 校验
        let v1 = try ProfileIO.decodeV1(from: manifestURL)
        try Validator().validate(v1)

        let profileRoot = manifestURL.deletingLastPathComponent()

        // 2. 解析 visual asset
        var visualURLs: [String: URL] = [:]
        let visualStates = v1.visual.states
        let visualPairs: [(String, String)] = [
            ("idle", visualStates.idle),
            ("focus", visualStates.focus),
            ("happy", visualStates.happy),
            ("tired", visualStates.tired),
            ("celebrate", visualStates.celebrate),
        ]
        for (k, rel) in visualPairs {
            let abs = Self.resolve(rel, in: profileRoot)
            try ensurePlaceholderImage(at: abs, label: "\(v1.name)/\(k)")
            visualURLs[k] = abs
        }

        // 3. 解析 expression asset
        var exprURLs: [String: URL] = [:]
        let exprFaces: [(String, String)] = [
            ("idle", v1.expression.states.idle.assetPath),
            ("focus", v1.expression.states.focus.assetPath),
            ("happy", v1.expression.states.happy.assetPath),
            ("tired", v1.expression.states.tired.assetPath),
            ("celebrate", v1.expression.states.celebrate.assetPath),
        ]
        for (k, rel) in exprFaces {
            let abs = Self.resolve(rel, in: profileRoot)
            try ensurePlaceholderImage(at: abs, label: "\(v1.name)/expr/\(k)")
            exprURLs[k] = abs
        }
        for (i, ext) in (v1.expression.extendedEmotions ?? []).enumerated() {
            let abs = Self.resolve(ext.assetPath, in: profileRoot)
            try ensurePlaceholderImage(at: abs, label: "\(v1.name)/expr/\(ext.name)")
            exprURLs["ext_\(i)_\(ext.name)"] = abs
        }

        // 4. action idle asset (optional)
        let idleAsset: URL?
        if let rel = v1.action.idle.assetPath {
            let abs = Self.resolve(rel, in: profileRoot)
            try ensurePlaceholderImage(at: abs, label: "\(v1.name)/action/idle")
            idleAsset = abs
        } else {
            idleAsset = nil
        }

        // 5. action reactions asset (可选)
        let reactionURLs: [URL?] = v1.action.reactions.map { r in
            guard let rel = r.assetPath else { return nil }
            let abs = Self.resolve(rel, in: profileRoot)
            return abs
        }
        for (i, r) in v1.action.reactions.enumerated() {
            guard let rel = r.assetPath else { continue }
            let abs = Self.resolve(rel, in: profileRoot)
            try ensurePlaceholderImage(at: abs, label: "\(v1.name)/action/reaction/\(r.name)_\(i)")
        }

        // 6. voice clone sample (optional)
        let sampleURL: URL?
        if let rel = v1.audio.voiceCloneConsent?.samplePath {
            sampleURL = Self.resolve(rel, in: profileRoot)
        } else {
            sampleURL = nil
        }

        return LoadedPetProfile(
            profileRoot: profileRoot,
            manifest: v1,
            visualAssetURLs: visualURLs,
            expressionAssetURLs: exprURLs,
            actionIdleAssetURL: idleAsset,
            actionReactionAssetURLs: reactionURLs,
            voiceCloneSampleURL: sampleURL
        )
    }

    // MARK: - path helpers

    /// 相对 → 绝对 URL。validator 已经把绝对路径 / '..' 拒了，所以这里安全。
    static func resolve(_ relative: String, in root: URL) -> URL {
        // 用 URL(fileURLWithPath:isDirectory:relativeTo:) 让 Foundation 处理 'a/b/c.png'
        return URL(fileURLWithPath: relative, relativeTo: root).standardizedFileURL
    }
}

// MARK: - LoaderError

public enum LoaderError: Error, CustomStringConvertible, Equatable {
    case placeholderGenerationFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .placeholderGenerationFailed(let p, let r):
            return "placeholder PNG generation failed at \(p): \(r)"
        }
    }
}

// MARK: - Placeholder PNG generator

/// 给 asset path 写一个 64x64 占位 PNG（透明背景 + 半透明圆角矩形 + 中心首字符）。
/// 如果文件已经存在就 skip；保证 idempotent。
///
/// 真实美术由 pet-asset 提供，runtime 只放占位，避免把 fixture 撑成大文件。
@discardableResult
public func ensurePlaceholderImage(at url: URL, label: String) throws -> URL {
    if FileManager.default.fileExists(atPath: url.path) {
        return url
    }
    // 确保父目录存在
    let parent = url.deletingLastPathComponent()
    if !FileManager.default.fileExists(atPath: parent.path) {
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw LoaderError.placeholderGenerationFailed(
                path: url.path,
                reason: "createDirectory failed: \(error.localizedDescription)"
            )
        }
    }
    // 生成 PNG
    do {
        try writePlaceholderPNG(to: url, label: label)
    } catch {
        throw LoaderError.placeholderGenerationFailed(
            path: url.path,
            reason: "PNG write failed: \(error.localizedDescription)"
        )
    }
    return url
}

/// 写一个最小可用的 64x64 PNG，透明背景，半透明圆角矩形 + 中心首字符。
/// 用 Core Graphics，不用第三方库。
func writePlaceholderPNG(to url: URL, label: String) throws {
    let size = 64
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw NSError(domain: "PlaceholderPNG", code: 1, userInfo: [NSLocalizedDescriptionKey: "CGContext init failed"])
    }

    // 透明背景（默认就是 0，clear 一下确保）
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // 半透明圆角矩形（灰底 + 灰边）
    ctx.setFillColor(CGColor(red: 0.7, green: 0.7, blue: 0.75, alpha: 0.55))
    let rect = CGRect(x: 4, y: 4, width: size - 8, height: size - 8)
    let path = CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil)
    ctx.addPath(path)
    ctx.fillPath()

    // 中心首字符（label 第一段首字符）
    let initial: String = label.first.map { String($0) } ?? "?"
    let font = NSFont.systemFont(ofSize: 26, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(white: 0.1, alpha: 0.85)
    ]
    let ns = (initial as NSString)
    let textSize = ns.size(withAttributes: attrs)
    let textRect = CGRect(
        x: (CGFloat(size) - textSize.width) / 2,
        y: (CGFloat(size) - textSize.height) / 2,
        width: textSize.width,
        height: textSize.height
    )
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    ns.draw(in: textRect, withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()

    // 写出 PNG
    guard let cgImage = ctx.makeImage() else {
        throw NSError(domain: "PlaceholderPNG", code: 2, userInfo: [NSLocalizedDescriptionKey: "CGContext.makeImage failed"])
    }
    let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    guard let dest else {
        throw NSError(domain: "PlaceholderPNG", code: 3, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationCreateWithURL failed"])
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    if !CGImageDestinationFinalize(dest) {
        throw NSError(domain: "PlaceholderPNG", code: 4, userInfo: [NSLocalizedDescriptionKey: "CGImageDestinationFinalize failed"])
    }
}

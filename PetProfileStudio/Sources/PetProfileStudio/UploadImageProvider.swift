// UploadImageProvider.swift
// UploadImageProvider — 默认 image provider。从本地 5 个 PNG 文件落到 pet profile。
//
// 行为（spec §3.1 + 任务描述）：
//   1. 检查 request.uploadURLs.count == 5（spec 要求 5 state 同步上传）
//   2. 校验每个 URL：存在 + PNG magic bytes (89 50 4E 47) + alpha channel + 尺寸 + < 5 MB
//   3. 校验 5 张图尺寸一致（同一 pet 内 visual identity 协调）
//   4. 把 5 张图复制到 {注入的 PetStore.root}/{pet_id}/assets/visual/states/{state}.png
//   5. 返回 ImageGenerationResult.states: [PetState: URL]
//
// 落盘路径：复用 PetStore 的 `assets/visual/states/{state}.png` 约定
//   —— manifest 顶层 `visual.states.{state}` 已经是相对路径 "assets/visual/states/{state}.png"
//   —— 上传实际**覆盖**该路径，manifest 引用本身不需要改
//
// 校验失败的语义：
//   - 落盘前任何校验失败 → throw ImageValidationError（含哪个 state + 哪个 check）
//   - 落盘过程中失败 → 抛 .writeFailed；已落盘的文件**不**回滚（user 重新上传整组即可）
//
// DI（P2-J 修复）：
//   - init 接受 PetStore（默认 .shared）—— 让测试可以注入临时 root，
//     避免污染用户真实 ~/Library/Application Support/oh-my-pet/pets/
//   - production 调用方（HouseViewModel）不传，自动走 .shared
//
// 不做：
//   - 不接 AI API（这是 upload provider 的契约）
//   - 不改 manifest 顶层（schema §2.5 不变量）
//   - 不引入第三方 PNG 库（用 Foundation + AppKit NSImage）
//   - 不跨 pet 共享（每个 pet 自己一份）
//

import Foundation
import AppKit
import PetProfile
import PetProfileRuntime

// MARK: - UploadImageProvider

public final class UploadImageProvider: ImageProvider, @unchecked Sendable {
    public static let providerID: String = "upload-local"

    public let id: String = UploadImageProvider.providerID
    public let displayName: String = "本地上传"
    public let requiresAPIKey: Bool = false

    /// 单张图最大 5 MB
    public let maxFileSize: Int = 5 * 1024 * 1024
    /// PNG magic bytes
    public let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// 注入的 PetStore（默认走 .shared）
    /// P2-J 修复：之前 hardcode `PetStore.shared` 导致测试污染真实 Application Support。
    public let store: PetStore

    /// - Parameter store: 可注入的 PetStore；测试传 temp store，production 不传走 .shared
    public init(store: PetStore = .shared) {
        self.store = store
    }

    public func generate(request: ImageGenerationRequest) async throws -> ImageGenerationResult {
        // 1. 数量校验
        try validateCount(request.uploadURLs)

        // 2. 按顺序逐张校验（PNG + alpha + 尺寸 + size）
        var firstSize: CGSize? = nil
        for (idx, url) in request.uploadURLs.enumerated() {
            let state = request.states[safe: idx] ?? Self.fallbackState(at: idx)
            try await validate(url: url, state: state, firstSize: &firstSize)
        }

        // 3. 落盘：复制到 {petRoot}/assets/visual/states/{state}.png
        //    P2-J 修复：用 self.store.petDirectory（注入），不是 PetStore.shared
        let petRoot = try resolvePetRoot(petID: request.petID)
        let statesDir = petRoot
            .appendingPathComponent("assets", isDirectory: true)
            .appendingPathComponent("visual", isDirectory: true)
            .appendingPathComponent("states", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: statesDir, withIntermediateDirectories: true)
        } catch {
            throw ImageValidationError(
                state: nil,
                check: .writeFailed,
                message: "create states dir failed: \(error.localizedDescription)"
            )
        }

        var resultStates: [VisualState: URL] = [:]
        for (idx, srcURL) in request.uploadURLs.enumerated() {
            let state = request.states[safe: idx] ?? Self.fallbackState(at: idx)
            let dstURL = statesDir.appendingPathComponent("\(state.rawValue).png")
            do {
                if FileManager.default.fileExists(atPath: dstURL.path) {
                    try? FileManager.default.removeItem(at: dstURL)
                }
                try FileManager.default.copyItem(at: srcURL, to: dstURL)
            } catch {
                throw ImageValidationError(
                    state: state,
                    check: .writeFailed,
                    message: "copy \(srcURL.lastPathComponent) → \(dstURL.lastPathComponent) failed: \(error.localizedDescription)"
                )
            }
            resultStates[state] = dstURL
        }

        let firstSrcSize = firstSize ?? .zero
        let metadata: [String: String] = [
            "source": "user-upload",
            "first_size": "\(Int(firstSrcSize.width))x\(Int(firstSrcSize.height))",
            "file_count": "\(request.uploadURLs.count)"
        ]
        return ImageGenerationResult(
            providerID: id,
            states: resultStates,
            generatedAt: Date(),
            metadata: metadata
        )
    }

    // MARK: - 校验

    func validateCount(_ urls: [URL]) throws {
        guard urls.count == 5 else {
            throw ImageValidationError(
                state: nil,
                check: .countMismatch,
                message: "expected exactly 5 PNGs, got \(urls.count)"
            )
        }
    }

    /// 校验单张图：存在 / PNG magic / alpha / 尺寸 / size。
    /// 第一次进入时记录尺寸到 firstSize（inout）；后续比对必须 == firstSize。
    /// 注：声明 async 是为了 future-proof（可能换成 actor-isolated 读 / async IO）；
    ///     当前实现是同步 file read + NSImage decode，async 不影响正确性。
    func validate(url: URL, state: VisualState, firstSize: inout CGSize?) async throws {
        // 1. 存在
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImageValidationError(
                state: state,
                check: .missingFile,
                message: "file not found: \(url.path)"
            )
        }

        // 2. 文件 size
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? Int) ?? 0
        guard fileSize <= maxFileSize else {
            throw ImageValidationError(
                state: state,
                check: .fileTooLarge,
                message: "file size \(fileSize) bytes > \(maxFileSize) bytes (5 MB)"
            )
        }

        // 3. PNG magic bytes（不依赖扩展名）
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw ImageValidationError(
                state: state,
                check: .decodeFailed,
                message: "read failed: \(error.localizedDescription)"
            )
        }
        guard data.count >= pngMagic.count else {
            throw ImageValidationError(
                state: state,
                check: .notPNG,
                message: "file too small to be PNG"
            )
        }
        let magicOK = data.prefix(pngMagic.count).elementsEqual(pngMagic)
        guard magicOK else {
            throw ImageValidationError(
                state: state,
                check: .notPNG,
                message: "magic bytes don't match PNG signature"
            )
        }

        // 4. 用 NSImage → CGImage 校验 alpha channel
        guard let nsImage = NSImage(contentsOf: url),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageValidationError(
                state: state,
                check: .decodeFailed,
                message: "NSImage/CGImage decode failed"
            )
        }
        let alphaInfo = cgImage.alphaInfo
        let hasAlpha = Self.alphaInfoHasAlpha(alphaInfo)
        guard hasAlpha else {
            throw ImageValidationError(
                state: state,
                check: .noAlphaChannel,
                message: "image has no alpha channel (alphaInfo=\(alphaInfo.rawValue))"
            )
        }

        // 5. 尺寸
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        if let ref = firstSize {
            if ref.width != size.width || ref.height != size.height {
                throw ImageValidationError(
                    state: state,
                    check: .sizeMismatch,
                    message: "size \(Int(size.width))x\(Int(size.height)) doesn't match first size \(Int(ref.width))x\(Int(ref.height))"
                )
            }
        } else {
            firstSize = size
        }
    }

    /// CGImageAlphaInfo 是否含 alpha 通道
    static func alphaInfoHasAlpha(_ info: CGImageAlphaInfo) -> Bool {
        switch info {
        case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly:
            return true
        case .none, .noneSkipFirst, .noneSkipLast:
            return false
        @unknown default:
            // 未知 raw value 兜底：保守视为有 alpha（PNG 默认 RGBA）
            return true
        }
    }

    // MARK: - 落盘路径

    /// 解析 pet 根目录（P2-J 修复后）。
    /// 直接走注入的 `self.store.petDirectory(for:)`；不再 hardcode PetStore.shared。
    /// production：self.store = PetStore.shared
    /// 测试：传入 temp store，输出落在 tmp dir（不会污染真实 ~/Library）
    func resolvePetRoot(petID: String) throws -> URL {
        let url = store.petDirectory(for: petID)
        // 即使目录还不存在也返回 URL（落盘阶段会 create）
        return url
    }

    // MARK: - 辅助

    /// states[idx] 越界时兜底（5 state 顺序对齐）
    static func fallbackState(at idx: Int) -> VisualState {
        let all = VisualState.allCases
        guard idx >= 0 && idx < all.count else { return .idle }
        return all[idx]
    }
}

// MARK: - 数组安全下标

extension Array {
    /// 安全下标 —— 越界返回 nil
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
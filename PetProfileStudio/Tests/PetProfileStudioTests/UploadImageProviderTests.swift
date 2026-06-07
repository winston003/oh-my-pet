// UploadImageProviderTests.swift
// UploadImageProvider 行为测试
//
// 覆盖：
//   - testGenerateSucceedsWith5ValidPNGs — 5 张合规 PNG（RGBA）→ 5 个 state URL + 文件落盘
//   - testGenerateFailsWhenNotExactly5Files — 4 张 / 6 张都 throw .countMismatch
//   - testGenerateFailsOnNonPNG — 用 JPEG magic bytes 写一个 .png 文件 → throw .notPNG
//   - testGenerateFailsOnOpaqueImage — RGB 无 alpha PNG → throw .noAlphaChannel
//   - testGenerateFailsOnSizeMismatch — 5 张尺寸不一致 → throw .sizeMismatch
//   - testGenerateFailsOnFileTooLarge — 6 MB → throw .fileTooLarge
//
// P2-J 增加（隔离验证）：
//   - testIsolatedTempStoreDoesNotPolluteRealAppSupport — 用 temp PetStore 跑 generate，
//     验证 output 在 tmp 下、用户真实 ~/Library/Application Support/oh-my-pet/pets/ 0 增长
//   - testPathInjectionFallback — 验证 init default 参数 = .shared（保留 production 行为）
//
// 工具：buildPNG(size:hasAlpha:) — 用 Core Graphics 动态生成 PNG bytes
//   - 64x64 默认（含 alpha）；传 hasAlpha=false 生成 opaque RGB
//
// P2-J 隔离要点：
//   - 所有测试都用 makeTempPetStore() 创建独立 PetStore
//   - UploadImageProvider.init 显式接收 PetStore（DI），不再 hardcode PetStore.shared
//   - 每个 test 结束 cleanup temp dir
//   - 关键断言：output URL hasPrefix tmpRoot，**不**触碰真实 Application Support

import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

func registerUploadImageProviderTests(_ tests: Tests) {
    // MARK: - PNG bytes 工厂

    /// 生成 PNG bytes；64x64 默认；hasAlpha=true 给 RGBA，false 给 RGB
    func makePNGBytes(width: Int = 64, height: Int = 64, hasAlpha: Bool = true) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGImageAlphaInfo.premultipliedLast.rawValue
        let bytesPerRow = width * 4
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )!
        if hasAlpha {
            context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.5)
        } else {
            context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        }
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let cgImageWithAlpha = context.makeImage()!
        let cgImage: CGImage
        if hasAlpha {
            cgImage = cgImageWithAlpha
        } else {
            cgImage = CGImage(
                width: cgImageWithAlpha.width,
                height: cgImageWithAlpha.height,
                bitsPerComponent: cgImageWithAlpha.bitsPerComponent,
                bitsPerPixel: 24,
                bytesPerRow: cgImageWithAlpha.width * 3,
                space: cgImageWithAlpha.colorSpace ?? colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: cgImageWithAlpha.dataProvider!,
                decode: cgImageWithAlpha.decode,
                shouldInterpolate: cgImageWithAlpha.shouldInterpolate,
                intent: cgImageWithAlpha.renderingIntent
            )!
        }
        let mutableData = NSMutableData()
        let type = UTType.png.identifier as CFString
        let dest = CGImageDestinationCreateWithData(mutableData, type, 1, nil)!
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return mutableData as Data
    }

    /// 写一个文件到 tmp，name 含后缀
    func writeBytes(_ data: Data, name: String, to dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    /// 写一个文件超过 5 MB — 用 sparse data
    func writeOversizePNG(name: String, to dir: URL, sizeBytes: Int) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let pngHeader = makePNGBytes(width: 64, height: 64, hasAlpha: true)
        var big = Data()
        big.append(pngHeader)
        big.append(Data(count: sizeBytes - pngHeader.count))
        try big.write(to: url)
        return url
    }

    // MARK: - 主测试（P2-J：所有测试都用 temp store + DI）

    /// 1) 5 张合规 PNG（RGBA）→ 5 个 state URL + 文件落盘（P2-J：注入 temp store）
    tests.add("Upload.testGenerateSucceedsWith5ValidPNGs") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        let provider = UploadImageProvider(store: store)
        var urls: [URL] = []
        for i in 0..<5 {
            let bytes = makePNGBytes()
            let url = try writeBytes(bytes, name: "img-\(i).png", to: tmp)
            urls.append(url)
        }

        let request = ImageGenerationRequest(
            petID: "pet_test01",
            states: VisualState.allCases,
            uploadURLs: urls
        )
        let result = try await provider.generate(request: request)

        try XCTAssertEqual(result.states.count, 5)
        for s in VisualState.allCases {
            try XCTAssertNotNil(result.states[s], "missing state \(s.rawValue)")
        }
        try XCTAssertEqual(result.providerID, "upload-local")
        let tmpStoreRoot = tmp.appendingPathComponent("store-root")
        for s in VisualState.allCases {
            let url = try XCTUnwrap(result.states[s])
            try XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "expected file at \(url.path)"
            )
            try XCTAssertTrue(
                url.path.hasPrefix(tmpStoreRoot.path),
                "output URL \(url.path) is NOT under temp store root \(tmpStoreRoot.path)"
            )
        }
    }

    /// 2) 不是 5 张 — 4 张 / 6 张都 throw（P2-J：注入 temp store）
    tests.add("Upload.testGenerateFailsWhenNotExactly5Files") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }
        let provider = UploadImageProvider(store: store)
        // 4 张
        do {
            let request = ImageGenerationRequest(
                petID: "pet_test01",
                states: Array(VisualState.allCases.prefix(4)),
                uploadURLs: (0..<4).map { URL(fileURLWithPath: "/tmp/x-\($0).png") }
            )
            _ = try await provider.generate(request: request)
            throw TestFailure(name: "count4", message: "expected throw for 4 files")
        } catch let v as ImageValidationError {
            try XCTAssertEqual(v.check, .countMismatch, "expected countMismatch, got \(v.check)")
        } catch {
            throw TestFailure(name: "count4", message: "wrong error: \(error)")
        }
        // 6 张
        do {
            var urls: [URL] = []
            for i in 0..<6 {
                let url = try writeBytes(makePNGBytes(), name: "x-\(i).png", to: tmp)
                urls.append(url)
            }
            let request = ImageGenerationRequest(
                petID: "pet_test01",
                states: VisualState.allCases,
                uploadURLs: urls
            )
            _ = try await provider.generate(request: request)
            throw TestFailure(name: "count6", message: "expected throw for 6 files")
        } catch let v as ImageValidationError {
            try XCTAssertEqual(v.check, .countMismatch, "expected countMismatch, got \(v.check)")
        } catch {
            throw TestFailure(name: "count6", message: "wrong error: \(error)")
        }
    }

    /// 3) 改 magic bytes 成 JPEG（FF D8 FF）→ throw .notPNG（P2-J：注入 temp store）
    tests.add("Upload.testGenerateFailsOnNonPNG") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        var urls: [URL] = []
        let jpegHeader: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46]
        for i in 0..<5 {
            var bytes = Data()
            bytes.append(contentsOf: jpegHeader)
            bytes.append(Data(count: 100))
            let url = try writeBytes(bytes, name: "fake-\(i).png", to: tmp)
            urls.append(url)
        }
        let provider = UploadImageProvider(store: store)
        let request = ImageGenerationRequest(
            petID: "pet_test01",
            states: VisualState.allCases,
            uploadURLs: urls
        )
        do {
            _ = try await provider.generate(request: request)
            throw TestFailure(name: "notPNG", message: "expected throw for non-PNG")
        } catch let v as ImageValidationError {
            try XCTAssertEqual(v.check, .notPNG, "expected notPNG, got \(v.check)")
        } catch {
            throw TestFailure(name: "notPNG", message: "wrong error: \(error)")
        }
    }

    /// 4) RGB 无 alpha PNG → throw .noAlphaChannel（P2-J：注入 temp store）
    tests.add("Upload.testGenerateFailsOnOpaqueImage") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        var urls: [URL] = []
        for i in 0..<5 {
            let bytes = makePNGBytes(hasAlpha: false)
            let url = try writeBytes(bytes, name: "rgb-\(i).png", to: tmp)
            urls.append(url)
        }
        let provider = UploadImageProvider(store: store)
        let request = ImageGenerationRequest(
            petID: "pet_test01",
            states: VisualState.allCases,
            uploadURLs: urls
        )
        do {
            _ = try await provider.generate(request: request)
            throw TestFailure(name: "opaque", message: "expected throw for opaque PNG")
        } catch let v as ImageValidationError {
            try XCTAssertEqual(v.check, .noAlphaChannel, "expected noAlphaChannel, got \(v.check)")
        } catch {
            throw TestFailure(name: "opaque", message: "wrong error: \(error)")
        }
    }

    /// 5) 5 张尺寸不一致 → throw .sizeMismatch（P2-J：注入 temp store）
    tests.add("Upload.testGenerateFailsOnSizeMismatch") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        var urls: [URL] = []
        for i in 0..<4 {
            let bytes = makePNGBytes(width: 64, height: 64)
            let url = try writeBytes(bytes, name: "small-\(i).png", to: tmp)
            urls.append(url)
        }
        let big = makePNGBytes(width: 128, height: 128)
        urls.append(try writeBytes(big, name: "big.png", to: tmp))

        let provider = UploadImageProvider(store: store)
        let request = ImageGenerationRequest(
            petID: "pet_test01",
            states: VisualState.allCases,
            uploadURLs: urls
        )
        do {
            _ = try await provider.generate(request: request)
            throw TestFailure(name: "mismatch", message: "expected throw for size mismatch")
        } catch let v as ImageValidationError {
            try XCTAssertEqual(v.check, .sizeMismatch, "expected sizeMismatch, got \(v.check)")
        } catch {
            throw TestFailure(name: "mismatch", message: "wrong error: \(error)")
        }
    }

    /// 6) 6 MB 文件 → throw .fileTooLarge（P2-J：注入 temp store）
    tests.add("Upload.testGenerateFailsOnFileTooLarge") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        var urls: [URL] = []
        for i in 0..<4 {
            let bytes = makePNGBytes()
            let url = try writeBytes(bytes, name: "ok-\(i).png", to: tmp)
            urls.append(url)
        }
        urls.append(try writeOversizePNG(name: "big.png", to: tmp, sizeBytes: 6 * 1024 * 1024))

        let provider = UploadImageProvider(store: store)
        let request = ImageGenerationRequest(
            petID: "pet_test01",
            states: VisualState.allCases,
            uploadURLs: urls
        )
        do {
            _ = try await provider.generate(request: request)
            throw TestFailure(name: "large", message: "expected throw for file > 5MB")
        } catch let v as ImageValidationError {
            try XCTAssertEqual(v.check, .fileTooLarge, "expected fileTooLarge, got \(v.check)")
        } catch {
            throw TestFailure(name: "large", message: "wrong error: \(error)")
        }
    }

    // MARK: - P2-J 隔离验证（NEW）

    /// P2-J NEW 1/2：temp PetStore 跑 generate，output 必须落在 tmp 下，
    /// 用户真实 ~/Library/Application Support/oh-my-pet/pets/ 0 增长。
    /// （这条是 P2-I verifier 标记的 test isolation concern 的核心回归测试）
    tests.add("Upload.testIsolatedTempStoreDoesNotPolluteRealAppSupport") { _ in
        let realRoot = realAppSupportPetsPath()
        let fm = FileManager.default
        let beforeFiles: [String]
        if fm.fileExists(atPath: realRoot.path) {
            let entries = (try? fm.contentsOfDirectory(atPath: realRoot.path)) ?? []
            beforeFiles = entries
        } else {
            beforeFiles = []
        }

        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        let provider = UploadImageProvider(store: store)
        var urls: [URL] = []
        for i in 0..<5 {
            let bytes = makePNGBytes()
            let url = try writeBytes(bytes, name: "iso-\(i).png", to: tmp)
            urls.append(url)
        }
        let request = ImageGenerationRequest(
            petID: "pet_isolation_test01",
            states: VisualState.allCases,
            uploadURLs: urls
        )
        let result = try await provider.generate(request: request)

        // 3. 断言：output URL 都在 tmp 下
        let tmpStoreRoot = tmp.appendingPathComponent("store-root")
        for s in VisualState.allCases {
            let url = try XCTUnwrap(result.states[s])
            try XCTAssertTrue(
                url.path.hasPrefix(tmpStoreRoot.path),
                "output URL \(url.path) leaked outside temp store root \(tmpStoreRoot.path)"
            )
        }

        // 4. 关键断言：用户真实 Application Support 内容没有变化
        let afterFiles: [String]
        if fm.fileExists(atPath: realRoot.path) {
            let entries = (try? fm.contentsOfDirectory(atPath: realRoot.path)) ?? []
            afterFiles = entries
        } else {
            afterFiles = []
        }
        let newFiles = afterFiles.filter { !beforeFiles.contains($0) }
        try XCTAssertEqual(
            newFiles,
            [],
            "test leaked into real ~/Library/Application Support/oh-my-pet/pets/ : \(newFiles)"
        )
    }

    /// P2-J NEW 2/2：UploadImageProvider() 无参数 init 必须仍能用 .shared
    /// （保留 production 行为，避免破坏既有调用方 HouseViewModel）
    tests.add("Upload.testPathInjectionFallback") { _ in
        // 不传 store → 应该自动 fall back 到 .shared
        let provider = UploadImageProvider()
        try XCTAssertTrue(
            provider.store === PetStore.shared,
            "default init must set store to PetStore.shared; got \(provider.store.root.path)"
        )
        try XCTAssertEqual(
            provider.store.root,
            PetStore.defaultRoot()
        )
    }
}
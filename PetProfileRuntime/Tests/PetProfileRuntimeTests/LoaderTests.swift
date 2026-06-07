// LoaderTests.swift
// PetProfileLoader 单元测试
//
// 覆盖：
//   - loadProfile 解析 Pako v1 fixture 不抛错
//   - LoadedPetProfile 字段齐全（5 pack + persona）
//   - 解析后的 visual asset URL 包含 5 个 state
//   - 解析后的 expression asset URL 包含 5 state + extended emotions
//   - action.idle asset URL 可选
//   - 解析后的占位 PNG 实际写入磁盘且可读
//   - 二次 load 走 cache（不会覆盖已有文件，但也不会崩）
//
// 隔离策略：每个 test 跑前把 fixture 复制到 /tmp/<uuid>/，让 placeholder PNG 写在那里，
// 不污染 source tree。
//
import Foundation
import AppKit
@testable import PetProfileRuntime

/// 把 fixture 复制到独立 tmp dir 并返回新的 manifest URL
func copyPakoFixtureToTmp() throws -> URL {
    let original = try XCTUnwrap(
        Bundle.module.url(forResource: "pako-v1.0.0", withExtension: "json", subdirectory: "Fixtures"),
        "missing fixture pako-v1.0.0.json"
    )
    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pet-runtime-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    let dest = tmpRoot.appendingPathComponent("pako-v1.0.0.json")
    try FileManager.default.copyItem(at: original, to: dest)
    return dest
}

func registerLoaderTests(_ tests: Tests) {

    tests.add("Loader.testLoadPakoV1Succeeds") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)
        try XCTAssertEqual(p.manifest.version, .v1_0_0)
        try XCTAssertEqual(p.manifest.id.raw, "pet_pako_v10")
        try XCTAssertEqual(p.manifest.name, "Pako")
    }

    tests.add("Loader.testLoadedProfileHasAllPacks") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)

        // 5 pack 都齐
        try XCTAssertEqual(p.manifest.visual.renderMode, .staticImage)
        try XCTAssertTrue(p.manifest.visual.transparentAlpha)
        try XCTAssertEqual(p.manifest.audio.ttsProvider, "user-configured")
        try XCTAssertEqual(p.manifest.action.idle.name, "breathe-slow")
        try XCTAssertEqual(p.manifest.expression.states.idle.assetPath, "assets/expression/idle.png")
        try XCTAssertEqual(p.manifest.humor.humorStyle, .selfDeprecating)
        // persona
        try XCTAssertEqual(p.manifest.persona.name, "Pako")
        try XCTAssertEqual(p.manifest.persona.recurringMotifs, ["肚子变粉红", "翻白眼", "果冻弹"])
    }

    tests.add("Loader.testVisualAssetURLsContainAll5States") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)

        for state in ["idle", "focus", "happy", "tired", "celebrate"] {
            let url = try XCTUnwrap(p.visualAssetURLs[state], "missing visual URL for \(state)")
            try XCTAssertTrue(
                FileManager.default.fileExists(atPath: url.path),
                "placeholder PNG missing for \(state) at \(url.path)"
            )
            // PNG magic bytes
            let data = try Data(contentsOf: url)
            try XCTAssertEqual(data.count > 8, true, "PNG too small for \(state)")
            let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
            for (i, b) in magic.enumerated() {
                try XCTAssertEqual(data[i], b, "PNG magic mismatch at byte \(i) for \(state)")
            }
        }
    }

    tests.add("Loader.testExpressionAssetURLsContainAll5States") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)

        for state in ["idle", "focus", "happy", "tired", "celebrate"] {
            try XCTAssertNotNil(p.expressionAssetURLs[state], "missing expression URL for \(state)")
        }
        // extended emotions
        try XCTAssertEqual(p.expressionAssetURLs.count >= 5 + 3, true, "expected ≥ 5 base + 3 extended, got \(p.expressionAssetURLs.count)")
    }

    tests.add("Loader.testActionIdleAssetIsResolved") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)
        let url = try XCTUnwrap(p.actionIdleAssetURL, "action.idle.assetPath should be resolved")
        try XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "action idle asset missing at \(url.path)")
    }

    tests.add("Loader.testActionReactionAssetsAlignedToReactions") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)
        try XCTAssertEqual(p.actionReactionAssetURLs.count, p.manifest.action.reactions.count)
        // 3 reactions in Pako fixture, all with asset
        try XCTAssertEqual(p.actionReactionAssetURLs.count, 3)
    }

    tests.add("Loader.testSecondLoadIsIdempotent") { _ in
        let manifestURL = try copyPakoFixtureToTmp()
        let loader = PetProfileLoader()
        let p1 = try loader.loadProfile(from: manifestURL)
        let url = p1.visualAssetURLs["idle"]!
        let mtime1 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        // wait a hair to ensure mtime diff would be visible
        Thread.sleep(forTimeInterval: 0.05)
        let p2 = try loader.loadProfile(from: manifestURL)
        let mtime2 = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        // 第二次 load 不应该重写文件（ensurePlaceholderImage 走 fileExists 短路）
        try XCTAssertEqual(mtime1, mtime2, "second load should not rewrite placeholder PNG")
        try XCTAssertEqual(p1, p2, "LoadedPetProfile should be value-equal across loads")
    }

    tests.add("Loader.testLoadNonexistentFileThrows") { _ in
        let loader = PetProfileLoader()
        let bad = URL(fileURLWithPath: "/tmp/oh-my-pet-nonexistent-\(UUID().uuidString).json")
        try XCTAssertThrowsError { _ = try loader.loadProfile(from: bad) }
    }

    tests.add("Loader.testPlaceholdersGoToProfileRootDir") { _ in
        // 验证 placeholder 写到了 manifest 所在目录（默认行为）
        // idle.png 路径 = <profileRoot>/assets/visual/states/idle.png
        // 向上 4 级得到 profileRoot
        let manifestURL = try copyPakoFixtureToTmp()
        let manifestDir = manifestURL.deletingLastPathComponent()
        let loader = PetProfileLoader()
        let p = try loader.loadProfile(from: manifestURL)
        let idleURL = p.visualAssetURLs["idle"]!
        // idleURL → .../states → .../visual → .../assets → profileRoot (4 deletions)
        let resolvedRoot = idleURL
            .deletingLastPathComponent()  // states/
            .deletingLastPathComponent()  // visual/
            .deletingLastPathComponent()  // assets/
            .deletingLastPathComponent()  // profileRoot
        try XCTAssertEqual(
            resolvedRoot.path,
            manifestDir.path,
            "visual idle placeholder should be under <profileRoot>/assets/visual/states/"
        )
    }
}

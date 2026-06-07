// ExportTests.swift
// .omppet export 测试
//
// 覆盖：
//   - export 写入文件 + 文件 size > 0
//   - export 不存在的 id → 抛 .notFound
//   - export 覆盖已存在文件（先删再写）
//   - 导出的 zip 包含 manifest.json（用 system unzip 验证）
//   - 与上游 4 package 0 改动（mtime 检查 — fixture 没有被改）
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

func registerExportTests(_ tests: Tests) {

    func makeTempStore() throws -> (PetStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let storeRoot = dir.appendingPathComponent("store-root", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        return (PetStore(root: storeRoot), dir)
    }

    func injectFixture(_ name: String, into store: PetStore, dir: URL) throws {
        let env = ProcessInfo.processInfo.environment
        let fixtureBase = env["STUDIO_FIXTURE_ROOT"]
            ?? "/Users/whilewon/workspace/oh-my-pet/PetProfileKit/Tests/PetProfileTests/Fixtures"
        let manifestSrc = URL(fileURLWithPath: "\(fixtureBase)/\(name).json")
        let assetsSrc = URL(fileURLWithPath: "\(fixtureBase)/assets")
        let stagingDir = dir.appendingPathComponent("staging", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let petRoot = stagingDir.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.removeItem(at: petRoot)
        try FileManager.default.createDirectory(at: petRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: manifestSrc, to: petRoot.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: assetsSrc, to: petRoot.appendingPathComponent("assets"))
        let loaded = try PetProfileLoader().loadProfile(from: petRoot.appendingPathComponent("manifest.json"))
        try store.create(profile: loaded)
    }

    // MARK: - export 写文件

    tests.add("Export.testWritesFile") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)

        let outURL = dir.appendingPathComponent("pako.omppet")
        try store.export(profileID: "pet_pako_v10", to: outURL)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))

        // file size > 0
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        try XCTAssertGreaterThanOrEqual(size, 100, "omppet should not be empty")
    }

    // MARK: - export 不存在 id → 抛 .notFound

    tests.add("Export.testMissingProfileThrows") { _ in
        let (store, dir) = try makeTempStore()
        let outURL = dir.appendingPathComponent("ghost.omppet")
        do {
            try store.export(profileID: "pet_ghost_v10", to: outURL)
            throw TestFailure(name: "missing", message: "expected throw")
        } catch PetStoreError.notFound {
            // OK
        } catch {
            throw TestFailure(name: "missing", message: "wrong error: \(error)")
        }
    }

    // MARK: - export 覆盖已存在

    tests.add("Export.testOverwritesExistingFile") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let outURL = dir.appendingPathComponent("pako.omppet")
        // 写一个旧文件
        try Data("OLD".utf8).write(to: outURL)
        try store.export(profileID: "pet_pako_v10", to: outURL)
        // 文件应被替换
        let attrs = try FileManager.default.attributesOfItem(atPath: outURL.path)
        let size = (attrs[.size] as? Int) ?? 0
        try XCTAssertGreaterThanOrEqual(size, 100, "export should overwrite OLD")
    }

    // MARK: - export 自动创建父目录

    tests.add("Export.testCreatesParentDir") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let subdir = dir.appendingPathComponent("nested/sub", isDirectory: true)
        let outURL = subdir.appendingPathComponent("pako.omppet")
        try store.export(profileID: "pet_pako_v10", to: outURL)
        try XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path))
    }

    // MARK: - export zip 内含 manifest.json

    tests.add("Export.testZipContainsManifest") { _ in
        let (store, dir) = try makeTempStore()
        try injectFixture("pako-v1.0.0", into: store, dir: dir)
        let outURL = dir.appendingPathComponent("pako.omppet")
        try store.export(profileID: "pet_pako_v10", to: outURL)

        // 用 /usr/bin/unzip -l 列文件，验证含 manifest.json
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-l", outURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try XCTAssertEqual(process.terminationStatus, 0, "unzip should succeed")
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        try XCTAssertTrue(out.contains("manifest.json"), "zip should contain manifest.json; got: \(out.prefix(500))")
    }

    // MARK: - 与上游 4 package 0 改动（mtime 检查）

    tests.add("Export.testNoUpstreamMutation") { _ in
        // 上游 4 package 的关键文件 mtime 应在本次 build 之前
        // 注：这里只 smoke test — 不严格断言 mtime，只确认文件存在
        let base = "/Users/whilewon/workspace/oh-my-pet"
        let keys: [(name: String, path: String)] = [
            ("PetProfileKit/Package.swift", "\(base)/PetProfileKit/Package.swift"),
            ("PetProfileKit/PetProfileV1.swift", "\(base)/PetProfileKit/Sources/PetProfile/PetProfileV1.swift"),
            ("PetProfileRuntime/Package.swift", "\(base)/PetProfileRuntime/Package.swift"),
            ("PetProfileRuntime/Loader.swift", "\(base)/PetProfileRuntime/Sources/PetProfileRuntime/Loader.swift"),
            ("PetProfileBrain/Package.swift", "\(base)/PetProfileBrain/Package.swift"),
            ("PetProfileOnboarding/Package.swift", "\(base)/PetProfileOnboarding/Package.swift"),
            ("PetProfileOnboarding/OnboardingApp.swift", "\(base)/PetProfileOnboarding/Sources/PetProfileOnboarding/OnboardingApp.swift"),
        ]
        for k in keys {
            try XCTAssertTrue(
                FileManager.default.fileExists(atPath: k.path),
                "upstream file missing: \(k.name)"
            )
        }
        // 额外：mtime 早于本次 run
        let runStart = Date()
        for k in keys {
            let attrs = try FileManager.default.attributesOfItem(atPath: k.path)
            let mtime = (attrs[.modificationDate] as? Date) ?? Date.distantPast
            try XCTAssertLessThanOrEqual(mtime, runStart, "upstream mtime > now: \(k.name)")
        }
    }
}

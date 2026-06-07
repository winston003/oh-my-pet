// TestProfileLoader.swift
// 测试用 helper — 加载 3 个 pet fixture 的 LoadedPetProfile
//
// 复用 v1.0.0 形式的 profile（从 PetProfileRuntime fixture 复制到本 package 的
// Tests/Fixtures/Profiles/ 下，避开 module 边界）。
//
// 把 fixture 复制到独立 tmp dir，避免 placeholder PNG 写到 source tree。
//
// Brain tests 不依赖 PetPanel / 不显示 NSPanel（用 ChannelSink mock 隔离）。
//

import Foundation
import PetProfile
@testable import PetProfileRuntime

func copyFixtureToTmp(_ name: String, subdirectory: String = "Fixtures/Profiles") throws -> URL {
    let original = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory),
        "missing fixture \(name).json in \(subdirectory) (not bundled into PetProfileBrainTests)"
    )
    let tmpRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pet-brain-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)
    let dest = tmpRoot.appendingPathComponent("\(name).json")
    try FileManager.default.copyItem(at: original, to: dest)
    return dest
}

/// 加载 Pako 的 LoadedPetProfile
func loadPakoProfile() throws -> LoadedPetProfile {
    let url = try copyFixtureToTmp("pako-v1.0.0")
    return try PetProfileLoader().loadProfile(from: url)
}

func loadMituProfile() throws -> LoadedPetProfile {
    let url = try copyFixtureToTmp("mitu-v1.0.0")
    return try PetProfileLoader().loadProfile(from: url)
}

func loadZorpProfile() throws -> LoadedPetProfile {
    let url = try copyFixtureToTmp("zorp-v1.0.0")
    return try PetProfileLoader().loadProfile(from: url)
}

// ImageProviderRegistryTests.swift
// ImageProviderRegistry 行为测试
//
// 覆盖：
//   - testDefaultIsUpload — defaultProvider().id == "upload-local"
//   - testAllProvidersIncludesUploadAndStubs — 3 个 provider 都在（upload + openai-dalle + stable-diffusion）
//   - testSharedSingletonHasBuiltIns — shared 单例有 3 个内置 provider
//   - testProviderLookupByID — provider(id:) 查
//
// P2-J：registry tests 也用 temp store 构造 UploadImageProvider，
// 万一未来有 test 调 generate() 不会污染真实 Application Support。
//

import Foundation
import PetProfile
import PetProfileRuntime
@testable import PetProfileStudio

func registerImageProviderRegistryTests(_ tests: Tests) {

    tests.add("Registry.testDefaultIsUpload") { _ in
        // P2-J：temp store 注入，避免 future-proof pollution
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        let registry = ImageProviderRegistry()
        // 注册 3 个（与 built-in 一致）；upload 用 temp store，AI stub 无 store 依赖
        registry.register(UploadImageProvider(store: store))
        registry.register(OpenAIDALLEImageProvider())
        registry.register(StableDiffusionImageProvider())

        let def = registry.defaultProvider()
        try XCTAssertEqual(def.id, "upload-local")
        try XCTAssertFalse(def.requiresAPIKey, "upload provider must NOT require API key")
        try XCTAssertEqual(def.displayName, "本地上传")
    }

    tests.add("Registry.testAllProvidersIncludesUploadAndStubs") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        let registry = ImageProviderRegistry()
        registry.register(UploadImageProvider(store: store))
        registry.register(OpenAIDALLEImageProvider())
        registry.register(StableDiffusionImageProvider())

        let all = registry.allProviders()
        let ids = Set(all.map { $0.id })
        try XCTAssertEqual(ids, ["upload-local", "openai-dalle", "stable-diffusion"])

        // AI providers 标记 requiresAPIKey
        for p in all where p.id != "upload-local" {
            try XCTAssertTrue(
                p.requiresAPIKey,
                "\(p.id) should require API key"
            )
        }
    }

    // 额外：shared 单例自动注册 3 个（启动期）
    // 注：shared 单例用的是 default-init UploadImageProvider（即 PetStore.shared）。
    // 这条测试只验证 provider 类型在列表里，不实际调 generate，所以不影响隔离。
    tests.add("Registry.testSharedSingletonHasBuiltIns") { _ in
        let shared = ImageProviderRegistry.shared
        let all = shared.allProviders()
        let ids = Set(all.map { $0.id })
        try XCTAssertTrue(ids.contains("upload-local"))
        try XCTAssertTrue(ids.contains("openai-dalle"))
        try XCTAssertTrue(ids.contains("stable-diffusion"))
        // default 仍是 upload
        try XCTAssertEqual(shared.defaultProvider().id, "upload-local")
    }

    // 额外：provider(id:) 查
    tests.add("Registry.testProviderLookupByID") { _ in
        let (store, tmp) = try makeTempPetStore()
        defer { cleanupTempPetStore(tmp) }

        let registry = ImageProviderRegistry()
        registry.register(UploadImageProvider(store: store))
        registry.register(OpenAIDALLEImageProvider())

        let upload = registry.provider(id: "upload-local")
        try XCTAssertNotNil(upload)
        try XCTAssertEqual(upload?.id, "upload-local")

        let openai = registry.provider(id: "openai-dalle")
        try XCTAssertNotNil(openai)
        try XCTAssertTrue(openai?.requiresAPIKey ?? false)

        let missing = registry.provider(id: "not-a-real-provider")
        try XCTAssertNil(missing)
    }
}
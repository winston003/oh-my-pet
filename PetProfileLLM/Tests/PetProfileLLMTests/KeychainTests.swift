// KeychainTests.swift
// KeychainKeyStore 单元测试
//
// 覆盖（per spec）：
//   - 写入 / 读取 / 删除 roundtrip（用 InMemoryKeychainBackend，不污染真 keychain）
//   - 列出 providers
//   - 覆盖已存在的 key（save 第二次 = replace）
//   - 错误路径：空 key / 空 provider 名
//   - 真实 SecurityFrameworkBackend 不在 unit test 里跑（避免污染 ~/Library/Keychain）
//
// 越界检查：
//   - 不调真 Keychain（不写 ~/.mavis/agents/.../keychain）
//   - 不依赖 `KeychainKeyStore.shared`（那是真后端）
//

import Foundation
@testable import PetProfileLLM

func registerKeychainTests(_ tests: Tests) {

    // MARK: - 基础 roundtrip

    tests.add("Keychain.testSaveLoadDelete_roundtrip") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)

        // 1. 空状态：找不到
        try XCTAssertNil(store.loadKey(forProvider: "openai"))

        // 2. 写
        try store.saveKey("sk-test-123", forProvider: "openai")
        try XCTAssertEqual(store.loadKey(forProvider: "openai"), "sk-test-123")

        // 3. 删
        try store.deleteKey(forProvider: "openai")
        try XCTAssertNil(store.loadKey(forProvider: "openai"))
    }

    tests.add("Keychain.testSave_overwriteExisting") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)

        try store.saveKey("sk-old", forProvider: "openai")
        try store.saveKey("sk-new", forProvider: "openai")
        try XCTAssertEqual(store.loadKey(forProvider: "openai"), "sk-new")
    }

    tests.add("Keychain.testMultipleProviders_isolated") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)

        try store.saveKey("sk-openai", forProvider: "openai")
        try store.saveKey("sk-claude", forProvider: "claude")
        try store.saveKey("sk-local", forProvider: "openai-compatible:http://localhost:11434")

        try XCTAssertEqual(store.loadKey(forProvider: "openai"), "sk-openai")
        try XCTAssertEqual(store.loadKey(forProvider: "claude"), "sk-claude")
        try XCTAssertEqual(store.loadKey(forProvider: "openai-compatible:http://localhost:11434"), "sk-local")
    }

    // MARK: - listProviders

    tests.add("Keychain.testListProviders_returnsAllAccounts") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)

        try store.saveKey("k1", forProvider: "openai")
        try store.saveKey("k2", forProvider: "claude")
        try store.saveKey("k3", forProvider: "openai-compatible:http://localhost:11434")

        let providers = try store.listProviders()
        // InMemoryKeychainBackend 返回 sorted
        try XCTAssertEqual(providers, [
            "claude",
            "openai",
            "openai-compatible:http://localhost:11434"
        ])
    }

    tests.add("Keychain.testListProviders_emptyReturnsEmpty") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        let providers = try store.listProviders()
        try XCTAssertEqual(providers, [])
    }

    // MARK: - 错误路径

    tests.add("Keychain.testSave_emptyKey_throws") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        try XCTAssertThrowsError {
            try store.saveKey("", forProvider: "openai")
        }
    }

    tests.add("Keychain.testSave_emptyProvider_throws") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        try XCTAssertThrowsError {
            try store.saveKey("sk-test", forProvider: "")
        }
    }

    tests.add("Keychain.testDelete_nonexistent_isIdempotent") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)
        // 不存在的 key 删除不抛错
        try store.deleteKey(forProvider: "openai")
        try store.deleteKey(forProvider: "claude")
        try XCTAssertEqual(store.listProviders(), [])
    }

    // MARK: - 后端实现

    tests.add("Keychain.testInMemoryBackend_resetClearsAll") { _ in
        let backend = InMemoryKeychainBackend()
        let store = KeychainKeyStore(backend: backend)

        try store.saveKey("k1", forProvider: "openai")
        try store.saveKey("k2", forProvider: "claude")
        try XCTAssertEqual(store.listProviders().count, 2)

        backend.reset()
        try XCTAssertEqual(store.listProviders(), [])
    }

    tests.add("Keychain.testSecurityBackend_constantsAreCorrect") { _ in
        // 不实际写真 keychain；只校验 service 名字 / 错误描述等常量
        // 这是 dry test — 防止有人把 service 改成 "oh-my-pet" 之类的弱名
        try XCTAssertEqual(KeychainConstants.serviceName, "oh-my-pet-llm-keys")
    }

    // MARK: - KeychainError

    tests.add("Keychain.testKeychainError_descriptions") { _ in
        // 验证错误消息是稳定的（UI / log grep 友好）
        try XCTAssertEqual(
            String(describing: KeychainError.itemNotFound),
            "Keychain item not found"
        )
        try XCTAssertEqual(
            String(describing: KeychainError.duplicateItem),
            "Keychain item already exists"
        )
        try XCTAssertContains(
            String(describing: KeychainError.unhandled(status: -25300)),
            "OSStatus -25300"
        )
    }
}

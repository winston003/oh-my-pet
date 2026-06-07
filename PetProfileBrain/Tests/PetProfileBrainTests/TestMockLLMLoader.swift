// TestMockLLMLoader.swift
// 测试用 helper — 加载 MockLLM fixture
//
// Bundle.module 是 SwiftPM 给 test target 自动生成的，
// library target 拿不到。所以 loader 放在 test target 里。
//

import Foundation
@testable import PetProfileBrain

enum TestMockLLMLoader {
    static let subdirectory = "Fixtures/LLMResponses"

    static func load(_ name: String) throws -> MockLLMFixture {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: subdirectory) else {
            throw NSError(
                domain: "TestMockLLMLoader", code: 404,
                userInfo: [NSLocalizedDescriptionKey: "missing fixture: \(name).json in \(subdirectory)"]
            )
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MockLLMFixture.self, from: data)
    }

    static func loadAll(prefix: String? = nil) throws -> [MockLLMFixture] {
        guard let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: subdirectory) else {
            return []
        }
        let sorted = urls
            .filter { prefix == nil || $0.lastPathComponent.hasPrefix(prefix!) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try sorted.map { try JSONDecoder().decode(MockLLMFixture.self, from: Data(contentsOf: $0)) }
    }
}

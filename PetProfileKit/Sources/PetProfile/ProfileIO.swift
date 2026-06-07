// ProfileIO.swift
// JSON 编解码 + 资源加载辅助
//
// 设计决策：
//   - encode 顺序：snake_case（下划线）—— 与 schema 草案一致
//   - 输出 JSON：prettyPrinted + sortedKeys（fixture diff 友好）
//   - 时间格式：ISO8601
//   - 不做隐式 schema 推断；调用方必须显式指定解码 v0.1.0 还是 v1.0.0
//

import Foundation

public enum ProfileIO {
    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - v1

    public static func encodeV1(_ p: PetProfileV1) throws -> Data {
        try encoder.encode(p)
    }

    public static func decodeV1(_ data: Data) throws -> PetProfileV1 {
        try decoder.decode(PetProfileV1.self, from: data)
    }

    public static func decodeV1(from url: URL) throws -> PetProfileV1 {
        let data = try Data(contentsOf: url)
        return try decodeV1(data)
    }

    // MARK: - v0.1.0

    public static func encodeV01(_ p: PetProfileV01) throws -> Data {
        try encoder.encode(p)
    }

    public static func decodeV01(_ data: Data) throws -> PetProfileV01 {
        try decoder.decode(PetProfileV01.self, from: data)
    }

    public static func decodeV01(from url: URL) throws -> PetProfileV01 {
        let data = try Data(contentsOf: url)
        return try decodeV01(data)
    }
}

// PetProfileV01Tests.swift
// v0.1.0 fixture 解析测试
//

import Foundation
@testable import PetProfile

func registerV01Tests(_ tests: Tests) {
    func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    tests.add("V01.testDecodePakoV01") { _ in
        let data = try loadFixture("pako-v0.1.0")
        let p = try ProfileIO.decodeV01(data)

        try XCTAssertEqual(p.version, "0.1.0")
        try XCTAssertEqual(p.id, "pet_pako_v01")
        try XCTAssertEqual(p.name, "Pako")
        try XCTAssertEqual(p.identity?.speciesPrompt, "ugly-cute jelly, deadpan and self-deprecating")
        try XCTAssertEqual(p.identity?.tone, "drawl-deadpan")
        try XCTAssertEqual(p.visualProfile.runtime, "static-image")
        try XCTAssertEqual(p.visualProfile.supportedRuntimes, ["static-image", "sprite", "video"])
        try XCTAssertEqual(p.visualProfile.states.idle, "assets/visual/states/idle.png")
        try XCTAssertEqual(p.visualProfile.states.celebrate, "assets/visual/states/celebrate.png")
        try XCTAssertEqual(p.voiceProfile.voiceId, "low-male-drawl")
        try XCTAssertEqual(p.voiceProfile.stylePrompt, "drawl-deadpan")
        try XCTAssertEqual(p.voiceProfile.consentConfirmed, true)
        try XCTAssertEqual(p.behaviorMap?.focusStarted, "focus")
        try XCTAssertEqual(p.behaviorMap?.taskCompleted, "happy")
        try XCTAssertNotNil(p.house)
        try XCTAssertEqual(p.house?.stickers?.count, 1)
        try XCTAssertEqual(p.house?.memories?.count, 1)
        try XCTAssertNotNil(p.visualProfile.generation)
    }

    tests.add("V01.testDecodeMituV01") { _ in
        let data = try loadFixture("mitu-v0.1.0")
        let p = try ProfileIO.decodeV01(data)
        try XCTAssertEqual(p.id, "pet_mitu_v01")
        try XCTAssertEqual(p.name, "Mitu")
        try XCTAssertEqual(p.identity?.tone, "warm-gentle")
        try XCTAssertEqual(p.voiceProfile.voiceId, "bright-female-soft")
    }

    tests.add("V01.testDecodeZorpV01") { _ in
        let data = try loadFixture("zorp-v0.1.0")
        let p = try ProfileIO.decodeV01(data)
        try XCTAssertEqual(p.id, "pet_zorp_v01")
        try XCTAssertEqual(p.name, "Zorp")
        try XCTAssertEqual(p.visualProfile.runtime, "sprite")
        try XCTAssertEqual(p.voiceProfile.voiceId, "electronic-haughty")
    }

    tests.add("V01.testRoundtrip") { _ in
        let data = try loadFixture("pako-v0.1.0")
        let p = try ProfileIO.decodeV01(data)
        let reencoded = try ProfileIO.encodeV01(p)
        let p2 = try ProfileIO.decodeV01(reencoded)
        try XCTAssertEqual(p, p2)
    }
}

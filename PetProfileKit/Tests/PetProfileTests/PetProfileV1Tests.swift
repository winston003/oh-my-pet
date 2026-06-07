// PetProfileV1Tests.swift
// v1.0.0 fixture 解析 + 5 pack 字段检查
//

import Foundation
@testable import PetProfile

func registerV1Tests(_ tests: Tests) {
    func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    tests.add("V1.testDecodePakoV1") { _ in
        let data = try loadFixture("pako-v1.0.0")
        let p = try ProfileIO.decodeV1(data)

        try XCTAssertEqual(p.version, .v1_0_0)
        try XCTAssertEqual(p.id.raw, "pet_pako_v10")
        try XCTAssertEqual(p.name, "Pako")
        try XCTAssertEqual(p.minRuntimeVersion, "0.1.0")
        try XCTAssertEqual(p.locale, "zh-CN")

        // visual
        try XCTAssertEqual(p.visual.renderMode, .staticImage)
        try XCTAssertTrue(p.visual.transparentAlpha)
        try XCTAssertTrue(p.visual.idleBreathing)
        try XCTAssertEqual(p.visual.states.idle, "assets/visual/states/idle.png")

        // audio
        try XCTAssertEqual(p.audio.ttsProvider, "user-configured")
        try XCTAssertEqual(p.audio.ttsVoice, "low-male-drawl")
        try XCTAssertEqualD(p.audio.voiceStyle.pitch, 0.85)
        try XCTAssertEqual(p.audio.voiceStyle.energy, .low)
        try XCTAssertEqual(p.audio.catchphrases.count, 3)
        try XCTAssertEqual(p.audio.catchphrases[0].trigger, .random)
        try XCTAssertEqual(p.audio.voiceCloneConsent?.samplePath, "assets/voice/samples/pako-sample.wav")
        try XCTAssertEqual(p.audio.voiceCloneConsent?.deletable, true)

        // action
        try XCTAssertEqual(p.action.idle.name, "breathe-slow")
        try XCTAssertEqual(p.action.idle.durationMs, 2000)
        try XCTAssertEqual(p.action.reactions.count, 3)
        try XCTAssertEqual(p.action.reactions[0].trigger, .click)
        try XCTAssertEqual(p.action.reactions[0].assetFormat, .springAnimation)

        // expression
        try XCTAssertEqual(p.expression.states.idle.assetPath, "assets/expression/idle.png")
        try XCTAssertEqual(p.expression.extendedEmotions?.count, 3)
        try XCTAssertEqual(p.expression.extendedEmotions?.first?.name, "chibi")

        // humor
        try XCTAssertEqual(p.humor.humorStyle, .selfDeprecating)
        try XCTAssertGreaterThanOrEqual(p.humor.personaSystemPrompt.count, 50)
        try XCTAssertLessThanOrEqual(p.humor.personaSystemPrompt.count, 2000)
        try XCTAssertEqualD(p.humor.jokeDensity, 0.4)
        try XCTAssertEqual(p.humor.selfDeprecationTopics?.count, 4)

        // persona
        try XCTAssertEqual(p.persona.name, "Pako")
        try XCTAssertLessThanOrEqual(p.persona.loreShort.count, 280)
        try XCTAssertEqual(p.persona.recurringMotifs, ["肚子变粉红", "翻白眼", "果冻弹"])
    }

    tests.add("V1.testDecodeMituV1") { _ in
        let data = try loadFixture("mitu-v1.0.0")
        let p = try ProfileIO.decodeV1(data)
        try XCTAssertEqual(p.id.raw, "pet_mitu_v10")
        try XCTAssertEqual(p.audio.voiceStyle.energy, .low)
        try XCTAssertEqual(p.humor.humorStyle, .gentle)
        try XCTAssertEqualD(p.humor.jokeDensity, 0.05)
        try XCTAssertNil(p.audio.voiceCloneConsent)
    }

    tests.add("V1.testDecodeZorpV1") { _ in
        let data = try loadFixture("zorp-v1.0.0")
        let p = try ProfileIO.decodeV1(data)
        try XCTAssertEqual(p.id.raw, "pet_zorp_v10")
        try XCTAssertEqual(p.visual.renderMode, .sprite)
        try XCTAssertEqual(p.humor.humorStyle, .sarcastic)
    }

    tests.add("V1.testValidateFixtures") { _ in
        let v = Validator()
        for name in ["pako-v1.0.0", "mitu-v1.0.0", "zorp-v1.0.0"] {
            let data = try loadFixture(name)
            let p = try ProfileIO.decodeV1(data)
            try XCTAssertNoThrow { try v.validate(p) }
        }
    }

    tests.add("V1.testRoundtrip") { _ in
        let data = try loadFixture("pako-v1.0.0")
        let p = try ProfileIO.decodeV1(data)
        let reencoded = try ProfileIO.encodeV1(p)
        let p2 = try ProfileIO.decodeV1(reencoded)
        try XCTAssertEqual(p, p2)
    }
}

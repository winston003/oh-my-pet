// UpgraderTests.swift
// v0.1.0 → v1.0.0 升级路径
//

import Foundation
@testable import PetProfile

func registerUpgraderTests(_ tests: Tests) {
    func loadFixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name)"
        )
        return try Data(contentsOf: url)
    }

    // MARK: - happy path

    tests.add("Upgrader.testUpgradePakoV01ToV1") { _ in
        let data = try loadFixture("pako-v0.1.0")
        let v01 = try ProfileIO.decodeV01(data)
        let result = try Upgrader.upgrade(v01)
        let v1 = result.profile

        try XCTAssertEqual(v1.version, .v1_0_0)
        try XCTAssertEqual(v1.id.raw, v01.id)
        try XCTAssertEqual(v1.name, "Pako")

        try XCTAssertEqual(v1.visual.states.idle, v01.visualProfile.states.idle)
        try XCTAssertEqual(v1.visual.states.focus, v01.visualProfile.states.focus)
        try XCTAssertEqual(v1.visual.states.happy, v01.visualProfile.states.happy)
        try XCTAssertEqual(v1.visual.states.tired, v01.visualProfile.states.tired)
        try XCTAssertEqual(v1.visual.states.celebrate, v01.visualProfile.states.celebrate)
        try XCTAssertEqual(v1.visual.renderMode, .staticImage)
        try XCTAssertTrue(v1.visual.transparentAlpha)
        try XCTAssertTrue(v1.visual.idleBreathing)

        try XCTAssertEqual(v1.audio.ttsProvider, "user-configured")
        try XCTAssertEqual(v1.audio.ttsVoice, "low-male-drawl")
        try XCTAssertEqual(v1.audio.voiceStyle.tone, "drawl-deadpan")
        try XCTAssertNotNil(v1.audio.voiceCloneConsent)
        try XCTAssertEqual(v1.audio.voiceCloneConsent?.samplePath, "assets/voice/samples/pako-sample.wav")

        let triggers = Set(v1.action.reactions.map { $0.trigger })
        try XCTAssertTrue(triggers.contains(.focusStart))
        try XCTAssertTrue(triggers.contains(.focusEnd))
        try XCTAssertTrue(triggers.contains(.shakeWindow))
        try XCTAssertTrue(triggers.contains(.taskDone))

        try XCTAssertEqual(v1.expression.states.idle.assetPath, v01.visualProfile.states.idle)
        try XCTAssertEqual(v1.expression.states.celebrate.assetPath, v01.visualProfile.states.celebrate)

        try XCTAssertGreaterThanOrEqual(v1.humor.personaSystemPrompt.count, 50)
        try XCTAssertLessThanOrEqual(v1.humor.personaSystemPrompt.count, 2000)

        try XCTAssertEqual(v1.persona.name, "Pako")
        try XCTAssertLessThanOrEqual(v1.persona.loreShort.count, 280)
        try XCTAssertEqual(v1.persona.backstoryTags, v01.identity?.personality)
    }

    tests.add("Upgrader.testUpgradeMituV01ToV1") { _ in
        let data = try loadFixture("mitu-v0.1.0")
        let v01 = try ProfileIO.decodeV01(data)
        let v1 = try Upgrader.upgrade(v01).profile

        try XCTAssertEqual(v1.name, "Mitu")
        try XCTAssertEqual(v1.audio.voiceStyle.tone, "warm-gentle")
        try XCTAssertEqual(v1.audio.ttsVoice, "bright-female-soft")
    }

    tests.add("Upgrader.testUpgradeZorpV01ToV1") { _ in
        let data = try loadFixture("zorp-v0.1.0")
        let v01 = try ProfileIO.decodeV01(data)
        let v1 = try Upgrader.upgrade(v01).profile

        try XCTAssertEqual(v1.name, "Zorp")
        try XCTAssertEqual(v1.visual.renderMode, .sprite)
        try XCTAssertEqual(v1.audio.voiceStyle.tone, "cold-sarcastic")
    }

    // MARK: - 丢失数据 + warning

    tests.add("Upgrader.testUpgradeDropsHouseWithWarning") { _ in
        let data = try loadFixture("pako-v0.1.0")
        let v01 = try ProfileIO.decodeV01(data)
        try XCTAssertNotNil(v01.house, "fixture must have house for this test")

        let result = try Upgrader.upgrade(v01)
        try XCTAssertTrue(
            result.warnings.contains(where: { $0.contains("'house'") }),
            "expected a warning about house being dropped"
        )
    }

    tests.add("Upgrader.testUpgradeDropsGenerationWithWarning") { _ in
        let data = try loadFixture("pako-v0.1.0")
        let v01 = try ProfileIO.decodeV01(data)
        try XCTAssertNotNil(v01.visualProfile.generation)

        let result = try Upgrader.upgrade(v01)
        try XCTAssertTrue(
            result.warnings.contains(where: { $0.lowercased().contains("generation") }),
            "expected a generation-dropped warning"
        )
    }

    // MARK: - placeholder voiceId

    tests.add("Upgrader.testUpgradePlaceholderVoiceIdTreatedAsMissing") { _ in
        let v01 = PetProfileV01(
            version: "0.1.0",
            id: "pet_placeholder_v01",
            name: "Placeholder",
            visualProfile: VisualProfile(
                runtime: "static-image",
                states: VisualStatesDict(
                    idle: "a.png", focus: "b.png", happy: "c.png", tired: "d.png", celebrate: "e.png"
                )
            ),
            voiceProfile: VoiceProfile(
                voiceId: "optional-provider-voice-id",
                stylePrompt: "neutral",
                sampleSource: "none",
                consentConfirmed: false
            ),
            behaviorMap: nil,
            house: nil
        )
        let v1 = try Upgrader.upgrade(v01).profile
        try XCTAssertEqual(v1.audio.ttsVoice, "user-configured")
        try XCTAssertNil(v1.audio.voiceCloneConsent)
    }

    tests.add("Upgrader.testUpgradeWithoutBehaviorMapProducesEmptyReactions") { _ in
        let v01 = PetProfileV01(
            version: "0.1.0",
            id: "pet_minimal_v01",
            name: "Minimal",
            visualProfile: VisualProfile(
                runtime: "static-image",
                states: VisualStatesDict(
                    idle: "a.png", focus: "b.png", happy: "c.png", tired: "d.png", celebrate: "e.png"
                )
            ),
            voiceProfile: VoiceProfile(provider: "x", voiceId: "y", stylePrompt: "z"),
            behaviorMap: nil,
            house: nil
        )
        let result = try Upgrader.upgrade(v01)
        try XCTAssertTrue(result.profile.action.reactions.isEmpty)
        try XCTAssertTrue(
            result.warnings.contains(where: { $0.contains("behaviorMap") }),
            "expected a behaviorMap warning"
        )
    }

    // MARK: - 升级结果必须通过 v1 validator

    tests.add("Upgrader.testUpgradeResultPassesV1Validator") { _ in
        for name in ["pako-v0.1.0", "mitu-v0.1.0", "zorp-v0.1.0"] {
            let data = try loadFixture(name)
            let v01 = try ProfileIO.decodeV01(data)
            let v1 = try Upgrader.upgrade(v01).profile
            try XCTAssertNoThrow({ try Validator().validate(v1) },
                "upgraded profile from \(name) must pass v1 validator"
            )
        }
    }

    // MARK: - 升级 → encode → decode → equal

    tests.add("Upgrader.testUpgradeRoundtrip") { _ in
        let data = try loadFixture("pako-v0.1.0")
        let v01 = try ProfileIO.decodeV01(data)
        let v1 = try Upgrader.upgrade(v01).profile

        let encoded = try ProfileIO.encodeV1(v1)
        let decoded = try ProfileIO.decodeV1(encoded)
        try XCTAssertEqual(v1, decoded)
    }
}

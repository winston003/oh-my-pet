// ValidatorTests.swift
// PetProfile v1 严格校验错误用例
//

import Foundation
@testable import PetProfile

func registerValidatorTests(_ tests: Tests) {
    let validator = Validator()

    // MARK: - 合法 baseline

    func makeValidProfile() -> PetProfileV1 {
        PetProfileV1(
            id: ProfileID(raw: "pet_pako_v10"),
            name: "Pako",
            visual: VisualPack(
                renderMode: .staticImage,
                states: VisualStates(
                    idle: "a/idle.png",
                    focus: "a/focus.png",
                    happy: "a/happy.png",
                    tired: "a/tired.png",
                    celebrate: "a/celebrate.png"
                )
            ),
            audio: AudioPack(
                ttsProvider: "user-configured",
                ttsVoice: "low-male-drawl",
                voiceStyle: VoiceStyle(pitch: 1.0, speed: 1.0, energy: .mid, tone: "neutral"),
                catchphrases: [],
                voiceCloneConsent: nil
            ),
            action: ActionPack(
                idle: IdleAction(name: "breathe", durationMs: 2000)
            ),
            expression: ExpressionPack(
                states: ExpressionStates(
                    idle: ExpressionFace(assetPath: "e/idle.png"),
                    focus: ExpressionFace(assetPath: "e/focus.png"),
                    happy: ExpressionFace(assetPath: "e/happy.png"),
                    tired: ExpressionFace(assetPath: "e/tired.png"),
                    celebrate: ExpressionFace(assetPath: "e/celebrate.png")
                )
            ),
            humor: HumorPack(
                humorStyle: .gentle,
                personaSystemPrompt: String(repeating: "x", count: 60)
            ),
            persona: PersonaCard(
                name: "Pako",
                loreShort: "An office jelly."
            )
        )
    }

    // MARK: - 测试用例

    tests.add("Validator.testValidProfilePasses") { _ in
        try XCTAssertNoThrow { try validator.validate(makeValidProfile()) }
    }

    tests.add("Validator.testMissingVersionFailsToDecode") { _ in
        let json = """
        {
          "id": "pet_pako_v10",
          "name": "Pako",
          "visual": { "render_mode": "static-image", "states": {} },
          "audio": {},
          "action": {},
          "expression": {},
          "humor": {},
          "persona": {}
        }
        """
        try XCTAssertThrowsError {
            _ = try ProfileIO.decoder.decode(PetProfileV1.self, from: Data(json.utf8))
        }
    }

    tests.add("Validator.testInvalidVersionRejected") { _ in
        let json = """
        {
          "version": "0.5.0",
          "id": "pet_pako_v10",
          "name": "Pako",
          "visual": {},
          "audio": {},
          "action": {},
          "expression": {},
          "humor": {},
          "persona": {}
        }
        """.data(using: .utf8)!
        try XCTAssertThrowsError {
            _ = try ProfileIO.decoder.decode(PetProfileV1.self, from: json)
        }
    }

    tests.add("Validator.testInvalidIDPattern") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: ProfileID(raw: "user_42"),
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.patternMismatch(path, _, _) {
            caught = (path == "id")
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected patternMismatch at id")
    }

    tests.add("Validator.testIDTooShort") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: ProfileID(raw: "pet_abc"),
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        try XCTAssertThrowsError { try validator.validate(bad) }
    }

    tests.add("Validator.testPitchOutOfRange") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: AudioPack(
                ttsProvider: p.audio.ttsProvider,
                ttsVoice: p.audio.ttsVoice,
                voiceStyle: VoiceStyle(pitch: 2.0, speed: 1.0, energy: .mid, tone: "x"),
                catchphrases: p.audio.catchphrases,
                voiceCloneConsent: p.audio.voiceCloneConsent
            ),
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.outOfRange(path, _, _, actual) {
            caught = (path == "audio.voice_style.pitch") && (abs(actual - 2.0) < 1e-9)
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected outOfRange at audio.voice_style.pitch")
    }

    tests.add("Validator.testSpeedOutOfRange") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: AudioPack(
                ttsProvider: p.audio.ttsProvider,
                ttsVoice: p.audio.ttsVoice,
                voiceStyle: VoiceStyle(pitch: 1.0, speed: 0.1, energy: .mid, tone: "x"),
                catchphrases: p.audio.catchphrases,
                voiceCloneConsent: p.audio.voiceCloneConsent
            ),
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        try XCTAssertThrowsError { try validator.validate(bad) }
    }

    tests.add("Validator.testJokeDensityOutOfRange") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: HumorPack(
                humorStyle: .gentle,
                personaSystemPrompt: String(repeating: "y", count: 60),
                jokeDensity: 1.5
            ),
            persona: p.persona
        )
        try XCTAssertThrowsError { try validator.validate(bad) }
    }

    tests.add("Validator.testPersonaSystemPromptTooShort") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: HumorPack(
                humorStyle: .gentle,
                personaSystemPrompt: "too short",
                jokeDensity: 0.3
            ),
            persona: p.persona
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.invalidValue(path, _, _) {
            caught = (path == "humor.persona_system_prompt")
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected invalidValue at humor.persona_system_prompt")
    }

    tests.add("Validator.testLoreShortTooLong") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: PersonaCard(
                name: "Pako",
                loreShort: String(repeating: "x", count: 281)
            )
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.invalidValue(path, _, _) {
            caught = (path == "persona.lore_short")
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected invalidValue at persona.lore_short")
    }

    tests.add("Validator.testAbsoluteAssetPathRejected") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: VisualPack(
                renderMode: .staticImage,
                states: VisualStates(
                    idle: "/etc/passwd",
                    focus: "a/focus.png",
                    happy: "a/happy.png",
                    tired: "a/tired.png",
                    celebrate: "a/celebrate.png"
                )
            ),
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.invalidValue(path, _, _) {
            caught = (path == "visual.states.idle")
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected invalidValue at visual.states.idle")
    }

    tests.add("Validator.testDotDotAssetPathRejected") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: VisualPack(
                renderMode: .staticImage,
                states: VisualStates(
                    idle: "assets/../secrets/idle.png",
                    focus: "a/focus.png",
                    happy: "a/happy.png",
                    tired: "a/tired.png",
                    celebrate: "a/celebrate.png"
                )
            ),
            audio: p.audio,
            action: p.action,
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        try XCTAssertThrowsError { try validator.validate(bad) }
    }

    tests.add("Validator.testActionDurationOutOfRange") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: ActionPack(
                idle: IdleAction(name: "breathe", durationMs: 50),
                reactions: []
            ),
            expression: p.expression,
            humor: p.humor,
            persona: p.persona
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.outOfRange(path, _, _, _) {
            caught = (path == "action.idle.duration_ms")
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected outOfRange at action.idle.duration_ms")
    }

    tests.add("Validator.testEmptyExpressionStateFails") { _ in
        let p = makeValidProfile()
        let bad = PetProfileV1(
            version: p.version,
            minRuntimeVersion: p.minRuntimeVersion,
            id: p.id,
            name: p.name,
            createdAt: p.createdAt,
            locale: p.locale,
            visual: p.visual,
            audio: p.audio,
            action: p.action,
            expression: ExpressionPack(
                states: ExpressionStates(
                    idle: ExpressionFace(assetPath: ""),
                    focus: ExpressionFace(assetPath: "e/focus.png"),
                    happy: ExpressionFace(assetPath: "e/happy.png"),
                    tired: ExpressionFace(assetPath: "e/tired.png"),
                    celebrate: ExpressionFace(assetPath: "e/celebrate.png")
                )
            ),
            humor: p.humor,
            persona: p.persona
        )
        var caught = false
        do {
            try validator.validate(bad)
        } catch let ValidationError.emptyField(path) {
            caught = (path == "expression.states.idle.asset_path")
        } catch {
            caught = false
        }
        try XCTAssertTrue(caught, "expected emptyField at expression.states.idle.asset_path")
    }
}

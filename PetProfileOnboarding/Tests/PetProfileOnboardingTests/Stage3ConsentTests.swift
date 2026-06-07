// Stage3ConsentTests.swift
// Stage 3 voice clone 显式 consent 校验（红线）
//
// 覆盖：
//   - 无 consent + cloned=true → OnboardingError.consentRequired
//   - 有 consent 但 userConfirmsOwnership=false → consentRequired
//   - 有 consent 且 userConfirmsOwnership=true → saveVoice(cloned:true) OK
//   - cloned=false 不需要 consent
//   - consent 字段缺失（userConfirmsOwnership=false）→ consent.isValid == false
//   - VoiceCloneConsent Codable roundtrip
//   - VoiceCloneConsent.isValid 边界（空 filename / false ownership / 缺 timestamp）
//   - recordVoiceCloneConsent 后才能 saveVoice(cloned:true)
//   - skip 路径（saveVoice(cloned:false)）不要求 consent
//

import Foundation
@testable import PetProfileOnboarding

func registerStage3ConsentTests(_ tests: Tests) {
    func makeFlow() throws -> (OnboardingFlow, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-consent-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = OnboardingStateStore.url(in: dir)
        var initial = OnboardingState()
        try initial.save(to: url)
        let loaded = try OnboardingState.load(from: url)
        return (OnboardingFlow(initialState: loaded, storeURL: url), url)
    }

    // MARK: - VoiceCloneConsent validity

    tests.add("Consent.testValidConsentIsValid") { _ in
        let c = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: true
        )
        try XCTAssertTrue(c.isValid)
    }

    tests.add("Consent.testInvalidWhenOwnershipFalse") { _ in
        let c = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: false
        )
        try XCTAssertFalse(c.isValid)
    }

    tests.add("Consent.testInvalidWhenFilenameEmpty") { _ in
        let c = VoiceCloneConsent(
            sampleFilename: "",
            userConfirmsOwnership: true
        )
        try XCTAssertFalse(c.isValid)
    }

    tests.add("Consent.testCodableRoundtrip") { _ in
        let c = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: true,
            consentTimestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(VoiceCloneConsent.self, from: data)
        try XCTAssertEqual(c, decoded)
    }

    // MARK: - 红线 1：无 consent 直接 saveVoice(cloned:true)

    tests.add("Consent.testSaveVoiceClonedWithoutConsentThrows") { _ in
        let (flow, _) = try makeFlow()
        // 没 recordVoiceCloneConsent → state.voiceCloneConsent == nil
        try XCTAssertThrowsError {
            try flow.saveVoice(style: nil, cloned: true)
        }
        do {
            try flow.saveVoice(style: nil, cloned: true)
        } catch let err as OnboardingError {
            try XCTAssertEqual(err, .consentRequired)
        }
    }

    // MARK: - 红线 2：有 consent 但 ownership=false

    tests.add("Consent.testSaveVoiceClonedWithInvalidConsentThrows") { _ in
        let (flow, _) = try makeFlow()
        let badConsent = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: false  // ← 红线
        )
        try flow.recordVoiceCloneConsent(badConsent)
        try XCTAssertThrowsError {
            try flow.saveVoice(style: nil, cloned: true)
        }
        do {
            try flow.saveVoice(style: nil, cloned: true)
        } catch let err as OnboardingError {
            try XCTAssertEqual(err, .consentRequired)
        }
    }

    // MARK: - 红线 3：consent 缺字段（filename 空）

    tests.add("Consent.testSaveVoiceClonedWithEmptyFilenameThrows") { _ in
        let (flow, _) = try makeFlow()
        let badConsent = VoiceCloneConsent(
            sampleFilename: "",  // ← 红线
            userConfirmsOwnership: true
        )
        try flow.recordVoiceCloneConsent(badConsent)
        try XCTAssertThrowsError {
            try flow.saveVoice(style: nil, cloned: true)
        }
    }

    // MARK: - Happy path：valid consent + cloned=true

    tests.add("Consent.testSaveVoiceClonedWithValidConsentSucceeds") { _ in
        let (flow, _) = try makeFlow()
        let goodConsent = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: true
        )
        try flow.recordVoiceCloneConsent(goodConsent)
        try XCTAssertNoThrow {
            try flow.saveVoice(style: nil, cloned: true)
        }
        try XCTAssertTrue(flow.state.voiceCloned)
        try XCTAssertEqual(flow.state.voiceCloneConsent?.sampleFilename, "user-sample.wav")
        try XCTAssertTrue(flow.state.voiceCloneConsent?.userConfirmsOwnership == true)
    }

    // MARK: - cloned=false 不需要 consent

    tests.add("Consent.testSaveVoiceNotClonedNoConsentRequired") { _ in
        let (flow, _) = try makeFlow()
        try XCTAssertNoThrow {
            try flow.saveVoice(style: "warm-gentle", cloned: false)
        }
        try XCTAssertFalse(flow.state.voiceCloned)
        try XCTAssertEqual(flow.state.voiceStyle, "warm-gentle")
        // skip 路径不留下 stale consent
        try XCTAssertNil(flow.state.voiceCloneConsent)
    }

    // MARK: - saveVoice(cloned:false) 清掉旧 consent

    tests.add("Consent.testSaveVoiceNotClonedClearsOldConsent") { _ in
        let (flow, _) = try makeFlow()
        // 先 record 一个 consent
        let goodConsent = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: true
        )
        try flow.recordVoiceCloneConsent(goodConsent)
        try XCTAssertNotNil(flow.state.voiceCloneConsent)

        // 然后 saveVoice(cloned:false) → 旧 consent 应被清掉
        try flow.saveVoice(style: "playful-bright", cloned: false)
        try XCTAssertNil(flow.state.voiceCloneConsent)
    }

    // MARK: - 端到端：Stage 1 → 1.5 → 2 → 3 (with consent) → 4 → completed

    tests.add("Consent.testEndToEndWithConsentPathA") { _ in
        let (flow, url) = try makeFlow()
        try flow.choose(path: .generate)
        try flow.saveByok(provider: "openai", keychainRef: "ref")
        try flow.next()
        try flow.saveProfile(at: URL(fileURLWithPath: "/tmp/p.omppet/manifest.json"))
        try flow.next()  // → voiceCreate

        // Stage 3：先 record consent 再 saveVoice(cloned:true)
        let consent = VoiceCloneConsent(
            sampleFilename: "user-sample.wav",
            userConfirmsOwnership: true
        )
        try flow.recordVoiceCloneConsent(consent)
        try flow.saveVoice(style: nil, cloned: true)
        try XCTAssertTrue(flow.state.voiceCloned)

        try flow.next()
        try XCTAssertEqual(flow.state.currentStage, .launchPet)
        try flow.markLaunched()
        try XCTAssertEqual(flow.state.currentStage, .completed)

        // 落盘验证
        let reloaded = try OnboardingState.load(from: url)
        try XCTAssertTrue(reloaded.voiceCloned)
        try XCTAssertEqual(reloaded.voiceCloneConsent?.sampleFilename, "user-sample.wav")
    }

    // MARK: - 端到端：Stage 1 → 3 (skip voice clone) → 4 → completed

    tests.add("Consent.testEndToEndSkipClonePathA") { _ in
        let (flow, url) = try makeFlow()
        try flow.choose(path: .generate)
        try flow.saveByok(provider: "default", keychainRef: nil)
        try flow.next()
        try flow.saveProfile(at: URL(fileURLWithPath: "/tmp/p.omppet/manifest.json"))
        try flow.next()  // → voiceCreate

        // Stage 3：选 style，不 clone
        try flow.saveVoice(style: "soft-fluffy", cloned: false)
        try XCTAssertFalse(flow.state.voiceCloned)
        try XCTAssertEqual(flow.state.voiceStyle, "soft-fluffy")

        try flow.next()
        try flow.markLaunched()
        try XCTAssertEqual(flow.state.currentStage, .completed)

        // 落盘验证：没有 consent 留下
        let reloaded = try OnboardingState.load(from: url)
        try XCTAssertFalse(reloaded.voiceCloned)
        try XCTAssertNil(reloaded.voiceCloneConsent)
        try XCTAssertEqual(reloaded.voiceStyle, "soft-fluffy")
    }
}

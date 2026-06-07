// PetPanelTests.swift
// PetPanel NSPanel 关键配置检查
//
// 覆盖（来自 pet-runtime rein agent.md）：
//   - styleMask 包含 borderless + nonactivatingPanel + resizable
//   - backgroundColor == .clear
//   - isOpaque == false
//   - hasShadow == false
//   - level == .floating
//   - collectionBehavior 包含 canJoinAllSpaces + fullScreenAuxiliary + stationary
//   - hidesOnDeactivate == true
//   - becomesKeyOnlyIfNeeded == true
//   - becomesKeyOnMainWindow == false
//   - isMovableByWindowBackground == true
//
// 额外：
//   - init 不抛错
//   - show() 不抛错（不需要 NSApp.run()；orderFrontRegardless 在没有 NSApp 时仍可调用）
//   - 加载 idle asset 后 contentView 装好
//   - switchVisualState 可以切到其他 state
//
import Foundation
import AppKit
@testable import PetProfileRuntime

func registerPetPanelTests(_ tests: Tests) {

    func loadPakoProfile() throws -> LoadedPetProfile {
        // 复制到 tmp dir，避免 placeholder PNG 写到 source tree
        let manifestURL = try copyPakoFixtureToTmp()
        return try PetProfileLoader().loadProfile(from: manifestURL)
    }

    // MARK: - init

    tests.add("PetPanel.testInitDoesNotThrow") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertNotNil(panel.contentView)
        try XCTAssertEqual(panel.profile.manifest.id.raw, "pet_pako_v10")
    }

    // MARK: - styleMask

    tests.add("PetPanel.testStyleMaskBorderlessNonactivatingResizable") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        let m = panel.styleMask
        try XCTAssertTrue(m.contains(.borderless), "missing .borderless in \(panel.styleMaskDescription)")
        try XCTAssertTrue(m.contains(.nonactivatingPanel), "missing .nonactivatingPanel in \(panel.styleMaskDescription)")
        try XCTAssertTrue(m.contains(.resizable), "missing .resizable in \(panel.styleMaskDescription)")
    }

    // MARK: - transparency

    tests.add("PetPanel.testBackgroundIsClear") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        // backgroundColor 在 AppKit 13+ 是 NSColor?
        let bgOpt = panel.backgroundColor
        try XCTAssertNotNil(bgOpt, "backgroundColor is nil")
        let bg = bgOpt!
        // NSColor.clear 的 RGBA 是 (0,0,0,0)。deviceRGB 才能拿到 RGB 数值
        let rgba = bg.usingColorSpace(.deviceRGB) ?? bg
        try XCTAssertEqualD(rgba.redComponent, 0.0, accuracy: 1e-3)
        try XCTAssertEqualD(rgba.greenComponent, 0.0, accuracy: 1e-3)
        try XCTAssertEqualD(rgba.blueComponent, 0.0, accuracy: 1e-3)
        try XCTAssertEqualD(rgba.alphaComponent, 0.0, accuracy: 1e-3)
    }

    tests.add("PetPanel.testIsOpaqueFalse") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertFalse(panel.isOpaque)
    }

    tests.add("PetPanel.testHasShadowFalse") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertFalse(panel.hasShadow)
    }

    // MARK: - level & collection behavior

    tests.add("PetPanel.testLevelIsFloating") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertEqual(panel.level, NSWindow.Level.floating)
    }

    tests.add("PetPanel.testCollectionBehaviorHasAll3") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        let b = panel.collectionBehavior
        try XCTAssertTrue(b.contains(.canJoinAllSpaces), "missing canJoinAllSpaces")
        try XCTAssertTrue(b.contains(.fullScreenAuxiliary), "missing fullScreenAuxiliary")
        try XCTAssertTrue(b.contains(.stationary), "missing stationary")
    }

    // MARK: - focus behavior

    tests.add("PetPanel.testHidesOnDeactivateTrue") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertTrue(panel.hidesOnDeactivate)
    }

    tests.add("PetPanel.testBecomesKeyOnlyIfNeededTrue") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertTrue(panel.becomesKeyOnlyIfNeeded)
    }

    tests.add("PetPanel.testBecomesKeyOnMainWindowFalse") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertFalse(panel.becomesKeyOnMainWindow)
    }

    // MARK: - drag

    tests.add("PetPanel.testIsMovableByWindowBackgroundTrue") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        try XCTAssertTrue(panel.isMovableByWindowBackground)
    }

    // MARK: - show & state

    tests.add("PetPanel.testShowDoesNotThrow") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        // orderFrontRegardless 在没有 NSApp.run() 时也可以调用，nudge 一下 window server
        panel.show()
        try XCTAssertEqual(panel.currentState, "idle")
    }

    tests.add("PetPanel.testSwitchVisualStateSucceeds") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        // happy 在 fixture 里也是合法 state
        let ok = panel.switchVisualState("happy")
        try XCTAssertTrue(ok, "switchVisualState(happy) should succeed")
        try XCTAssertEqual(panel.currentState, "happy")
        // 切回 idle
        let back = panel.switchVisualState("idle")
        try XCTAssertTrue(back)
    }

    tests.add("PetPanel.testSwitchVisualStateBogusReturnsFalse") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        let ok = panel.switchVisualState("nonexistent")
        try XCTAssertFalse(ok)
        // currentState 不变
        try XCTAssertEqual(panel.currentState, "idle")
    }

    tests.add("PetPanel.testConfigurationDescriptionContainsAllKeys") { _ in
        let p = try loadPakoProfile()
        let panel = PetPanel(profile: p)
        let s = panel.configurationDescription()
        for key in [
            "styleMask", "backgroundColor", "isOpaque", "hasShadow",
            "level", "collectionBehavior", "hidesOnDeactivate",
            "becomesKeyOnlyIfNeeded", "becomesKeyOnMainWindow",
            "isMovableByWindowBackground", "ignoresMouseEvents",
            "minSize", "maxSize", "currentState"
        ] {
            try XCTAssertTrue(s.contains(key), "configurationDescription missing key: \(key)")
        }
    }
}

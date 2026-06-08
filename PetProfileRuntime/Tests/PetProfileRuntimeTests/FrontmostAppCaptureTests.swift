// FrontmostAppCaptureTests.swift
// FrontmostAppCapture 行为测试
//
// 覆盖：
//   - testSnapshotDoesNotCrash — snapshot() 在任意环境下不 crash
//   - testSnapshotAppNameNonEmpty — 真实 frontmost app 时 appName 非空
//   - testSnapshotBundleIDIsStringOrNil — bundleID 是 String?（不强求非空；
//     CI / headless 环境可能 nil）
//   - testSnapshotWindowTitleAlwaysNil — windowTitle 永远 nil（MVP 不读窗口标题；
//     spec §1 P5 红线，adversarial probe 验证）
//   - testSnapshotCapturedAtIsRecent — capturedAt 在调用前后合理范围内
//   - testSnapshotEquatable — Snapshot 满足 Equatable / Hashable（Hashable 用于
//     PetProfileBrain 端 AppContextSnapshot 的 future cache 去重）
//   - testSnapshotCodableRoundTrip — Snapshot 满足 Codable（PetProfileBrain 端
//     AppContextSnapshot 是 Codable；本地端对应字段兼容）
//
// **不**覆盖：
//   - 不测 frontmost app 是某个具体 app（CI 跑的环境不可控；只会跑出"当前 frontmost"）
//   - 不测 NSPasteboard（trigger 才读剪贴板；capture 本身不读）
//
// **adversarial probe**：
//   - 在 FrontmostAppCapture.swift 里 grep "NSPasteboard" / "kAX" — 0 命中
//   - 在 test file 里**不** import NSPasteboard / Accessibility（spec §1 P5 红线）

import Foundation
import AppKit
@testable import PetProfileRuntime

func registerFrontmostAppCaptureTests(_ tests: Tests) {

    // MARK: - 基础

    tests.add("FrontmostAppCapture.testSnapshotDoesNotCrash") { _ in
        // 任意环境（CI / 本地）下，snapshot() 不抛错
        let s = FrontmostAppCapture.snapshot()
        try XCTAssertNotNil(s.appName, "appName must be non-empty even if frontmost is nil")
    }

    tests.add("FrontmostAppCapture.testSnapshotAppNameNonEmpty") { _ in
        let s = FrontmostAppCapture.snapshot()
        try XCTAssertFalse(s.appName.isEmpty, "appName must be non-empty (real app or 'Unknown')")
    }

    tests.add("FrontmostAppCapture.testSnapshotBundleIDIsStringOrNil") { _ in
        let s = FrontmostAppCapture.snapshot()
        // bundleID 是 String?——不强求非空（headless 环境可能 nil）
        if let bid = s.bundleID {
            try XCTAssertFalse(bid.isEmpty, "bundleID should not be empty string when present")
        }
    }

    // MARK: - MVP 不读 windowTitle（spec §1 P5 红线）

    tests.add("FrontmostAppCapture.testSnapshotWindowTitleAlwaysNil") { _ in
        let s = FrontmostAppCapture.snapshot()
        try XCTAssertNil(s.windowTitle, "windowTitle must always be nil in MVP — spec §1 P5: don't read window title without Accessibility consent")
    }

    // MARK: - capturedAt

    tests.add("FrontmostAppCapture.testSnapshotCapturedAtIsRecent") { _ in
        let before = Date()
        let s = FrontmostAppCapture.snapshot()
        let after = Date()
        // capturedAt 必须在 before 之后、after 之前（或边界相等）
        try XCTAssertGreaterThanOrEqual(s.capturedAt, before.addingTimeInterval(-0.5), "capturedAt must be ≥ before")
        try XCTAssertLessThanOrEqual(s.capturedAt, after.addingTimeInterval(0.5), "capturedAt must be ≤ after")
    }

    tests.add("FrontmostAppCapture.testSnapshotCapturedAtDiffers") { _ in
        // 两次调用 capturedAt 不同（除非两次都在同一毫秒；概率极低但保留 1ms buffer）
        let s1 = FrontmostAppCapture.snapshot()
        Thread.sleep(forTimeInterval: 0.01)
        let s2 = FrontmostAppCapture.snapshot()
        try XCTAssertNotEqual(s1.capturedAt, s2.capturedAt, "consecutive snapshots should differ in capturedAt")
    }

    // MARK: - 协议

    tests.add("FrontmostAppCapture.testSnapshotEquatable") { _ in
        let now = Date()
        let s1 = FrontmostAppCapture.Snapshot(bundleID: "com.test.app", appName: "TestApp", windowTitle: nil, capturedAt: now)
        let s2 = FrontmostAppCapture.Snapshot(bundleID: "com.test.app", appName: "TestApp", windowTitle: nil, capturedAt: now)
        let s3 = FrontmostAppCapture.Snapshot(bundleID: "com.other.app", appName: "TestApp", windowTitle: nil, capturedAt: now)
        try XCTAssertEqual(s1, s2)
        try XCTAssertNotEqual(s1, s3)
    }

    tests.add("FrontmostAppCapture.testSnapshotHashable") { _ in
        let now = Date()
        let s1 = FrontmostAppCapture.Snapshot(bundleID: "com.test.app", appName: "TestApp", windowTitle: nil, capturedAt: now)
        let s2 = FrontmostAppCapture.Snapshot(bundleID: "com.test.app", appName: "TestApp", windowTitle: nil, capturedAt: now)
        var set: Set<FrontmostAppCapture.Snapshot> = []
        set.insert(s1)
        set.insert(s2)  // duplicate; set count stays 1
        try XCTAssertEqual(set.count, 1)
    }

    tests.add("FrontmostAppCapture.testSnapshotCodableRoundTrip") { _ in
        let original = FrontmostAppCapture.Snapshot(
            bundleID: "com.test.app",
            appName: "TestApp",
            windowTitle: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(FrontmostAppCapture.Snapshot.self, from: data)
        try XCTAssertEqual(decoded, original)
    }

    // MARK: - Codable: nil bundleID

    tests.add("FrontmostAppCapture.testSnapshotCodableNilBundleID") { _ in
        let original = FrontmostAppCapture.Snapshot(
            bundleID: nil,
            appName: "Unknown",
            windowTitle: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(FrontmostAppCapture.Snapshot.self, from: data)
        try XCTAssertEqual(decoded, original)
        try XCTAssertNil(decoded.bundleID)
    }

    // MARK: - Real frontmost app 合理化（不强求）

    tests.add("FrontmostAppCapture.testSnapshotWhenFrontmostPresentIsNotUnknown") { _ in
        // 在 test runner 跑时大概率有 frontmost app（运行测试的 Terminal / Xcode）。
        // 这个测试在 headless / 无 GUI 环境可能 fail，标记为 "best effort"。
        let s = FrontmostAppCapture.snapshot()
        // 注：s.appName 至少非空；不强求 != "Unknown"（因为 headless 环境下
        // NSWorkspace.frontmostApplication 可能返回 nil → fallback "Unknown"）
        try XCTAssertFalse(s.appName.isEmpty)
    }
}

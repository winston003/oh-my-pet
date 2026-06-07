// SpringAnimationTests.swift
// SpringAnimation + SpringParams 单元测试
//
// 覆盖（任务 spec "Jelly bounce spring 参数" + 派生测试）：
//   - jellyBounceParams 全部常量匹配 mvp-pet-decision.md 决策
//   - simulateScale 在 t=0 / t=peak / t=end / t=duration 严格命中
//   - 关键帧之间 cubic ease 平滑
//   - 边界：t<0 → initial，t>duration → rest，duration=0 → rest（不 NaN）
//   - defaultSpringParams / namedParams lookup
//   - scale 序列有界（在 [min, max] 内，不发散）
//
// P2-A3 新增（Mitu + Zorp 招牌反应）：
//   - mituFurShakeParams / mituCurlParams / zorpTentacleSlapParams / zorpSpinParams
//     全部常量精确匹配任务 spec（mvp-pet-decision.md 第 2 节"招牌动作"对照表）
//   - 4 个 namedParams 查表命中（Pako + Mitu + Zorp 共 5 个 name）
//   - 3 个关键帧采样点（t=0 / t=peak / t=end）每只 pet 至少 1 组
//   - 各 pet 曲线有界 + 连续性（用 P2-A2 已有的 sample 算法，扩展到 4 个新 params）
//
// 隔离：纯函数，不需要 fixture / NSApplication。

import Foundation
@testable import PetProfileRuntime

func registerSpringAnimationTests(_ tests: Tests) {

    // MARK: - jellyBounceParams

    tests.add("SpringAnimation.testJellyBounceParamsMatchSpec") { _ in
        let p = SpringAnimation.jellyBounceParams()
        try XCTAssertEqualD(p.duration, 0.4, accuracy: 1e-9, "jelly-bounce duration should be 0.4s")
        try XCTAssertEqualD(p.damping, 0.45, accuracy: 1e-9, "jelly-bounce damping should be 0.45")
        try XCTAssertEqualD(p.initialScale, 0.8, accuracy: 1e-9, "jelly-bounce initialScale should be 0.8")
        try XCTAssertEqualD(p.peakScale, 1.1, accuracy: 1e-9, "jelly-bounce peakScale should be 1.1")
        try XCTAssertEqualD(p.secondScale, 0.95, accuracy: 1e-9, "jelly-bounce secondScale should be 0.95")
        try XCTAssertEqualD(p.restScale, 1.0, accuracy: 1e-9, "jelly-bounce restScale should be 1.0")
    }

    tests.add("SpringAnimation.testJellyBounceParamsEquatable") { _ in
        let a = SpringAnimation.jellyBounceParams()
        let b = SpringAnimation.jellyBounceParams()
        try XCTAssertEqual(a, b, "jellyBounceParams should be deterministic / value-equal")
    }

    // MARK: - simulateScale keyframes

    tests.add("SpringAnimation.testSimulateScaleAtZeroIsInitial") { _ in
        let p = SpringAnimation.jellyBounceParams()
        let s = SpringAnimation.simulateScale(at: 0.0, params: p)
        try XCTAssertEqualD(s, p.initialScale, accuracy: 1e-9)
    }

    tests.add("SpringAnimation.testSimulateScaleAtPeakTimeIsPeak") { _ in
        // 关键帧 k1 在 normalized 0.25 = 0.4 * 0.25 = 0.1s
        let p = SpringAnimation.jellyBounceParams()
        let s = SpringAnimation.simulateScale(at: p.duration * 0.25, params: p)
        try XCTAssertEqualD(s, p.peakScale, accuracy: 1e-9, "t=0.1s should be peakScale (1.1)")
    }

    tests.add("SpringAnimation.testSimulateScaleAtSecondTimeIsSecond") { _ in
        // 关键帧 k2 在 normalized 0.55 = 0.4 * 0.55 = 0.22s
        let p = SpringAnimation.jellyBounceParams()
        let s = SpringAnimation.simulateScale(at: p.duration * 0.55, params: p)
        try XCTAssertEqualD(s, p.secondScale, accuracy: 1e-9, "t=0.22s should be secondScale (0.95)")
    }

    tests.add("SpringAnimation.testSimulateScaleAtEndIsRest") { _ in
        let p = SpringAnimation.jellyBounceParams()
        let s = SpringAnimation.simulateScale(at: p.duration, params: p)
        try XCTAssertEqualD(s, p.restScale, accuracy: 1e-9, "t=duration should be restScale (1.0)")
    }

    // MARK: - boundaries

    tests.add("SpringAnimation.testSimulateScaleBeforeZeroIsInitial") { _ in
        let p = SpringAnimation.jellyBounceParams()
        let s = SpringAnimation.simulateScale(at: -1.0, params: p)
        try XCTAssertEqualD(s, p.initialScale, accuracy: 1e-9, "t<0 should clamp to initialScale")
    }

    tests.add("SpringAnimation.testSimulateScaleAfterDurationIsRest") { _ in
        let p = SpringAnimation.jellyBounceParams()
        let s = SpringAnimation.simulateScale(at: 99.0, params: p)
        try XCTAssertEqualD(s, p.restScale, accuracy: 1e-9, "t>duration should clamp to restScale")
    }

    tests.add("SpringAnimation.testSimulateScaleZeroDurationNoNaN") { _ in
        let p = SpringParams(
            duration: 0.0, damping: 0.5,
            initialScale: 0.8, peakScale: 1.1, secondScale: 0.95, restScale: 1.0
        )
        // t>duration 应该走 rest
        let s = SpringAnimation.simulateScale(at: 0.5, params: p)
        try XCTAssertFalse(s.isNaN, "must not produce NaN with zero duration")
        try XCTAssertEqualD(s, p.restScale, accuracy: 1e-9)
    }

    // MARK: - shape properties

    tests.add("SpringAnimation.testSimulateScalePeaksAtKeyframe") { _ in
        // Pako jelly-bounce 的 peak 1.1 必须能在 [0, duration] 内取到
        let p = SpringAnimation.jellyBounceParams()
        var maxScale: Double = -.infinity
        var maxT: TimeInterval = 0
        let step: TimeInterval = 0.001
        var t: TimeInterval = 0
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            if s > maxScale {
                maxScale = s
                maxT = t
            }
            t += step
        }
        // 关键帧 k1 在 0.1s 处是 peak；cubic ease 在 0.1s 处的值就是 1.1
        try XCTAssertEqualD(maxScale, p.peakScale, accuracy: 1e-3,
                            "scan max should hit peakScale 1.1 at ~0.1s; got \(maxScale) at t=\(maxT)")
    }

    tests.add("SpringAnimation.testSimulateScaleBoundedInRange") { _ in
        let p = SpringAnimation.jellyBounceParams()
        let lo = min(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        let hi = max(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        var t: TimeInterval = 0
        let step: TimeInterval = 0.002
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertGreaterThanOrEqual(s, lo - 1e-6, "scale below lo at t=\(t): \(s)")
            try XCTAssertLessThanOrEqual(s, hi + 1e-6, "scale above hi at t=\(t): \(s)")
            t += step
        }
    }

    tests.add("SpringAnimation.testSimulateScaleContinuous") { _ in
        // 相邻 sample 差距 < 0.05（粗略连续性检查，cubic ease 是 C1 连续）
        let p = SpringAnimation.jellyBounceParams()
        let step: TimeInterval = 0.001
        var prev = SpringAnimation.simulateScale(at: 0, params: p)
        var t: TimeInterval = step
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            let diff = abs(s - prev)
            try XCTAssertLessThanOrEqual(diff, 0.05, "scale jump too big at t=\(t): \(prev) → \(s)")
            prev = s
            t += step
        }
    }

    tests.add("SpringAnimation.testSimulateScaleFirstSegmentMonotonic") { _ in
        // 第一段 [0, 0.1s] 从 0.8 单调上升到 1.1
        let p = SpringAnimation.jellyBounceParams()
        var prev = SpringAnimation.simulateScale(at: 0, params: p)
        var t: TimeInterval = 0.005
        while t < 0.1 {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertGreaterThanOrEqual(s, prev - 1e-9, "first segment should be non-decreasing at t=\(t)")
            prev = s
            t += 0.005
        }
    }

    tests.add("SpringAnimation.testSimulateScaleSecondSegmentMonotonicDown") { _ in
        // 第二段 [0.1s, 0.22s] 从 1.1 单调下降到 0.95
        let p = SpringAnimation.jellyBounceParams()
        var prev = SpringAnimation.simulateScale(at: 0.1, params: p)
        var t: TimeInterval = 0.105
        while t <= 0.22 + 1e-6 {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertLessThanOrEqual(s, prev + 1e-9, "second segment should be non-increasing at t=\(t)")
            prev = s
            t += 0.01
        }
    }

    tests.add("SpringAnimation.testSimulateScaleThirdSegmentMonotonicUpToRest") { _ in
        // 第三段 [0.22s, 0.4s] 从 0.95 单调上升到 1.0
        let p = SpringAnimation.jellyBounceParams()
        var prev = SpringAnimation.simulateScale(at: 0.22, params: p)
        var t: TimeInterval = 0.23
        while t <= p.duration + 1e-6 {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertGreaterThanOrEqual(s, prev - 1e-9, "third segment should be non-decreasing at t=\(t)")
            prev = s
            t += 0.01
        }
    }

    // MARK: - namedParams / default

    tests.add("SpringAnimation.testNamedParamsKnown") { _ in
        let p = try XCTUnwrap(SpringAnimation.namedParams("jelly-bounce"))
        try XCTAssertEqual(p, SpringAnimation.jellyBounceParams())
    }

    tests.add("SpringAnimation.testNamedParamsUnknownReturnsNil") { _ in
        let p = SpringAnimation.namedParams("nonexistent-thing")
        try XCTAssertNil(p)
    }

    tests.add("SpringAnimation.testDefaultSpringParamsSane") { _ in
        let p = SpringAnimation.defaultSpringParams()
        try XCTAssertGreaterThanOrEqual(p.duration, 0.1)
        try XCTAssertLessThanOrEqual(p.duration, 2.0)
        try XCTAssertGreaterThanOrEqual(p.peakScale, 1.0, "default peak should be overshoot > 1.0")
        try XCTAssertLessThanOrEqual(p.secondScale, 1.0, "default second should be undershoot < 1.0")
        try XCTAssertEqualD(p.restScale, 1.0, accuracy: 1e-9)
    }

    // MARK: - Mitu mituFurShakeParams (P2-A3)

    tests.add("SpringAnimation.testMituFurShakeParamsMatchSpec") { _ in
        // 任务 spec 严格匹配 mvp-pet-decision.md 第 2 节 Mitu 招牌反应
        let p = SpringAnimation.mituFurShakeParams()
        try XCTAssertEqualD(p.duration, 0.5, accuracy: 1e-9, "fur-shake-look-up duration should be 0.5s")
        try XCTAssertEqualD(p.damping, 0.5, accuracy: 1e-9, "fur-shake-look-up damping should be 0.5")
        try XCTAssertEqualD(p.initialScale, 1.0, accuracy: 1e-9, "fur-shake-look-up initialScale should be 1.0")
        try XCTAssertEqualD(p.peakScale, 1.05, accuracy: 1e-9, "fur-shake-look-up peakScale should be 1.05")
        try XCTAssertEqualD(p.secondScale, 0.98, accuracy: 1e-9, "fur-shake-look-up secondScale should be 0.98")
        try XCTAssertEqualD(p.restScale, 1.0, accuracy: 1e-9, "fur-shake-look-up restScale should be 1.0")
    }

    tests.add("SpringAnimation.testMituFurShakeKeyframes") { _ in
        // 3 关键帧采样点：t=0 / t=peak / t=end
        let p = SpringAnimation.mituFurShakeParams()
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: 0, params: p), p.initialScale,
            accuracy: 1e-9, "t=0 should be initialScale (1.0)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.25, params: p), p.peakScale,
            accuracy: 1e-9, "t=0.125s should be peakScale (1.05)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.55, params: p), p.secondScale,
            accuracy: 1e-9, "t=0.275s should be secondScale (0.98)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration, params: p), p.restScale,
            accuracy: 1e-9, "t=0.5s should be restScale (1.0)")
    }

    tests.add("SpringAnimation.testMituFurShakeBounded") { _ in
        // 曲线全程在 [min(0.98, 1.0, 1.05, 1.0), max(...)] = [0.98, 1.05] 内
        let p = SpringAnimation.mituFurShakeParams()
        let lo = min(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        let hi = max(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        var t: TimeInterval = 0
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertGreaterThanOrEqual(s, lo - 1e-6, "scale below lo at t=\(t): \(s)")
            try XCTAssertLessThanOrEqual(s, hi + 1e-6, "scale above hi at t=\(t): \(s)")
            t += 0.002
        }
    }

    // MARK: - Mitu mituCurlParams (P2-A3)

    tests.add("SpringAnimation.testMituCurlParamsMatchSpec") { _ in
        // curl-into-ball 是反向 spring：peak 0.6（挤压）→ second 1.05（弹开）
        let p = SpringAnimation.mituCurlParams()
        try XCTAssertEqualD(p.duration, 1.0, accuracy: 1e-9, "curl-into-ball duration should be 1.0s")
        try XCTAssertEqualD(p.damping, 0.6, accuracy: 1e-9, "curl-into-ball damping should be 0.6")
        try XCTAssertEqualD(p.initialScale, 1.0, accuracy: 1e-9, "curl-into-ball initialScale should be 1.0")
        try XCTAssertEqualD(p.peakScale, 0.6, accuracy: 1e-9, "curl-into-ball peakScale should be 0.6 (squeezed in)")
        try XCTAssertEqualD(p.secondScale, 1.05, accuracy: 1e-9, "curl-into-ball secondScale should be 1.05 (bounced out)")
        try XCTAssertEqualD(p.restScale, 1.0, accuracy: 1e-9, "curl-into-ball restScale should be 1.0")
    }

    tests.add("SpringAnimation.testMituCurlKeyframes") { _ in
        let p = SpringAnimation.mituCurlParams()
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: 0, params: p), p.initialScale,
            accuracy: 1e-9, "t=0 should be initialScale (1.0)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.25, params: p), p.peakScale,
            accuracy: 1e-9, "t=0.25s should be peakScale (0.6, squeezed in)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.55, params: p), p.secondScale,
            accuracy: 1e-9, "t=0.55s should be secondScale (1.05, bounced out)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration, params: p), p.restScale,
            accuracy: 1e-9, "t=1.0s should be restScale (1.0)")
    }

    tests.add("SpringAnimation.testMituCurlReachesMinAndMax") { _ in
        // curl-into-ball 是唯一有 peak < 1.0 的招牌 spring，验证它在 [0, duration] 内
        // 真的取到 0.6（关键帧）和 1.05（第二帧反弹过冲）
        let p = SpringAnimation.mituCurlParams()
        var minScale: Double = .infinity
        var maxScale: Double = -.infinity
        var t: TimeInterval = 0
        let step: TimeInterval = 0.002
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            if s < minScale { minScale = s }
            if s > maxScale { maxScale = s }
            t += step
        }
        try XCTAssertEqualD(minScale, p.peakScale, accuracy: 1e-3,
                            "scan min should hit peakScale 0.6; got \(minScale)")
        try XCTAssertEqualD(maxScale, p.secondScale, accuracy: 1e-3,
                            "scan max should hit secondScale 1.05; got \(maxScale)")
    }

    // MARK: - Zorp zorpTentacleSlapParams (P2-A3)

    tests.add("SpringAnimation.testZorpTentacleSlapParamsMatchSpec") { _ in
        let p = SpringAnimation.zorpTentacleSlapParams()
        try XCTAssertEqualD(p.duration, 0.4, accuracy: 1e-9, "tentacle-slap duration should be 0.4s")
        try XCTAssertEqualD(p.damping, 0.4, accuracy: 1e-9, "tentacle-slap damping should be 0.4")
        try XCTAssertEqualD(p.initialScale, 1.0, accuracy: 1e-9, "tentacle-slap initialScale should be 1.0")
        try XCTAssertEqualD(p.peakScale, 1.15, accuracy: 1e-9, "tentacle-slap peakScale should be 1.15")
        try XCTAssertEqualD(p.secondScale, 0.92, accuracy: 1e-9, "tentacle-slap secondScale should be 0.92")
        try XCTAssertEqualD(p.restScale, 1.0, accuracy: 1e-9, "tentacle-slap restScale should be 1.0")
    }

    tests.add("SpringAnimation.testZorpTentacleSlapKeyframes") { _ in
        let p = SpringAnimation.zorpTentacleSlapParams()
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: 0, params: p), p.initialScale,
            accuracy: 1e-9, "t=0 should be initialScale (1.0)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.25, params: p), p.peakScale,
            accuracy: 1e-9, "t=0.1s should be peakScale (1.15)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.55, params: p), p.secondScale,
            accuracy: 1e-9, "t=0.22s should be secondScale (0.92)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration, params: p), p.restScale,
            accuracy: 1e-9, "t=0.4s should be restScale (1.0)")
    }

    tests.add("SpringAnimation.testZorpTentacleSlapHasLargestPeak") { _ in
        // tentacle-slap peak 1.15 是 Pako jelly-bounce (1.1) 和 Mitu fur-shake (1.05) 之上的
        // 第二大（仅次于 spin-rainbow 1.2）。验证它确实 ≥ 其他两个正向 spring。
        let slap = SpringAnimation.zorpTentacleSlapParams()
        let jelly = SpringAnimation.jellyBounceParams()
        let shake = SpringAnimation.mituFurShakeParams()
        try XCTAssertGreaterThanOrEqual(slap.peakScale, jelly.peakScale,
                                        "tentacle-slap peak should be ≥ jelly-bounce (戏剧感)")
        try XCTAssertGreaterThanOrEqual(slap.peakScale, shake.peakScale,
                                        "tentacle-slap peak should be ≥ fur-shake (振幅大)")
    }

    // MARK: - Zorp zorpSpinParams (P2-A3)

    tests.add("SpringAnimation.testZorpSpinParamsMatchSpec") { _ in
        let p = SpringAnimation.zorpSpinParams()
        try XCTAssertEqualD(p.duration, 1.0, accuracy: 1e-9, "spin-rainbow duration should be 1.0s")
        try XCTAssertEqualD(p.damping, 0.3, accuracy: 1e-9, "spin-rainbow damping should be 0.3 (弹性最强)")
        try XCTAssertEqualD(p.initialScale, 1.0, accuracy: 1e-9, "spin-rainbow initialScale should be 1.0")
        try XCTAssertEqualD(p.peakScale, 1.2, accuracy: 1e-9, "spin-rainbow peakScale should be 1.2 (5 pet 中最大)")
        try XCTAssertEqualD(p.secondScale, 0.9, accuracy: 1e-9, "spin-rainbow secondScale should be 0.9")
        try XCTAssertEqualD(p.restScale, 1.0, accuracy: 1e-9, "spin-rainbow restScale should be 1.0")
    }

    tests.add("SpringAnimation.testZorpSpinKeyframes") { _ in
        let p = SpringAnimation.zorpSpinParams()
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: 0, params: p), p.initialScale,
            accuracy: 1e-9, "t=0 should be initialScale (1.0)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.25, params: p), p.peakScale,
            accuracy: 1e-9, "t=0.25s should be peakScale (1.2)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration * 0.55, params: p), p.secondScale,
            accuracy: 1e-9, "t=0.55s should be secondScale (0.9)")
        try XCTAssertEqualD(
            SpringAnimation.simulateScale(at: p.duration, params: p), p.restScale,
            accuracy: 1e-9, "t=1.0s should be restScale (1.0)")
    }

    tests.add("SpringAnimation.testZorpSpinHasSmallestDamping") { _ in
        // damping 0.3 = 5 pet 中最小（弹性最强），符合"彩虹色旋转"戏剧性
        let spin = SpringAnimation.zorpSpinParams()
        let jelly = SpringAnimation.jellyBounceParams()
        let shake = SpringAnimation.mituFurShakeParams()
        let curl = SpringAnimation.mituCurlParams()
        let slap = SpringAnimation.zorpTentacleSlapParams()
        try XCTAssertLessThan(spin.damping, jelly.damping, "spin damping should be < jelly (弹性最强)")
        try XCTAssertLessThan(spin.damping, shake.damping, "spin damping should be < shake")
        try XCTAssertLessThan(spin.damping, curl.damping, "spin damping should be < curl")
        try XCTAssertLessThan(spin.damping, slap.damping, "spin damping should be < slap")
    }

    // MARK: - 5 pet namedParams 表（P2-A3 扩展到 5 项）

    tests.add("SpringAnimation.testNamedParamsAllFiveReactions") { _ in
        // 5 pet 招牌反应 namedParams 都查得到
        try XCTAssertEqual(SpringAnimation.namedParams("jelly-bounce"), SpringAnimation.jellyBounceParams())
        try XCTAssertEqual(SpringAnimation.namedParams("fur-shake-look-up"), SpringAnimation.mituFurShakeParams())
        try XCTAssertEqual(SpringAnimation.namedParams("curl-into-ball"), SpringAnimation.mituCurlParams())
        try XCTAssertEqual(SpringAnimation.namedParams("tentacle-slap"), SpringAnimation.zorpTentacleSlapParams())
        try XCTAssertEqual(SpringAnimation.namedParams("spin-rainbow"), SpringAnimation.zorpSpinParams())
    }

    tests.add("SpringAnimation.testNamedParamsCrossPetDistinct") { _ in
        // 5 个 namedParams 互不相等（防 pet-A spring 串到 pet-B）
        let p1 = try XCTUnwrap(SpringAnimation.namedParams("jelly-bounce"))
        let p2 = try XCTUnwrap(SpringAnimation.namedParams("fur-shake-look-up"))
        let p3 = try XCTUnwrap(SpringAnimation.namedParams("curl-into-ball"))
        let p4 = try XCTUnwrap(SpringAnimation.namedParams("tentacle-slap"))
        let p5 = try XCTUnwrap(SpringAnimation.namedParams("spin-rainbow"))
        // 任取两个不相等的 sanity check
        try XCTAssertNotEqual(p1, p2, "Pako jelly-bounce should differ from Mitu fur-shake")
        try XCTAssertNotEqual(p1, p3, "Pako jelly-bounce should differ from Mitu curl (反向曲线)")
        try XCTAssertNotEqual(p1, p4, "Pako jelly-bounce should differ from Zorp tentacle-slap")
        try XCTAssertNotEqual(p1, p5, "Pako jelly-bounce should differ from Zorp spin")
        try XCTAssertNotEqual(p2, p3, "Mitu fur-shake should differ from curl")
        try XCTAssertNotEqual(p4, p5, "Zorp tentacle-slap should differ from spin")
    }

    // MARK: - 4 个新 spring 的连续性 + 段内单调（cubic ease 不变）

    tests.add("SpringAnimation.testMituFurShakeContinuous") { _ in
        // Mitu fur-shake 全程连续：相邻 sample 差 < 0.05
        let p = SpringAnimation.mituFurShakeParams()
        let step: TimeInterval = 0.001
        var prev = SpringAnimation.simulateScale(at: 0, params: p)
        var t: TimeInterval = step
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertLessThanOrEqual(abs(s - prev), 0.05,
                "scale jump too big at t=\(t): \(prev) → \(s)")
            prev = s
            t += step
        }
    }

    tests.add("SpringAnimation.testMituCurlFirstSegmentMonotonicDown") { _ in
        // Mitu curl 第一段 [0, 0.25s] 从 1.0 单调下降到 0.6（挤成毛球）
        let p = SpringAnimation.mituCurlParams()
        var prev = SpringAnimation.simulateScale(at: 0, params: p)
        var t: TimeInterval = 0.01
        while t < 0.25 {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertLessThanOrEqual(s, prev + 1e-9,
                "curl first segment should be non-increasing at t=\(t)")
            prev = s
            t += 0.01
        }
    }

    tests.add("SpringAnimation.testZorpTentacleSlapBounded") { _ in
        let p = SpringAnimation.zorpTentacleSlapParams()
        let lo = min(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        let hi = max(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        var t: TimeInterval = 0
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertGreaterThanOrEqual(s, lo - 1e-6, "scale below lo at t=\(t): \(s)")
            try XCTAssertLessThanOrEqual(s, hi + 1e-6, "scale above hi at t=\(t): \(s)")
            t += 0.002
        }
    }

    tests.add("SpringAnimation.testZorpSpinBounded") { _ in
        let p = SpringAnimation.zorpSpinParams()
        let lo = min(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        let hi = max(p.initialScale, p.peakScale, p.secondScale, p.restScale)
        var t: TimeInterval = 0
        while t <= p.duration {
            let s = SpringAnimation.simulateScale(at: t, params: p)
            try XCTAssertGreaterThanOrEqual(s, lo - 1e-6, "scale below lo at t=\(t): \(s)")
            try XCTAssertLessThanOrEqual(s, hi + 1e-6, "scale above hi at t=\(t): \(s)")
            t += 0.002
        }
    }
}

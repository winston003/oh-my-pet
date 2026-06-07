// SpringAnimation.swift
// Spring 动画数学 + 纯函数
//
// 责任：
//   - 描述 spring 动画参数（SpringParams）
//   - 给 3 只 pet 的招牌反应锁定一套参数：
//     * Pako jellyBounceParams           — 果冻弹（click）
//     * Mitu mituFurShakeParams          — 抖毛 + 抬头（click）
//     * Mitu mituCurlParams              — 蜷成毛球 + 弹开（longPress）
//     * Zorp zorpTentacleSlapParams      — 触手甩开（click）
//     * Zorp zorpSpinParams              — 旋开 + 收（doubleClick）
//   - 提供纯函数 simulateScale(at:params:) 用于测试 + 将来 NSPanel 渲染复用
//
// 设计决策：
//   - **纯函数，不接 NSView / CASpringAnimation**：
//     1. 可单测（不需要 window server / display link）
//     2. 不绑定渲染后端（以后想换 SwiftUI / Metal / 自家 sprite 都行）
//     3. PetPanel+VisualState 把"画出来"的事接过，SpringAnimation 只算 scale 值
//   - 关键帧（normalized 0..1）+ 段内 cubic ease-in-out：
//     简单、可读、4 关键帧（initial / peak / second / rest）刚好描述果冻弹
//   - damping 字段保留但暂不参与曲线计算（CASpringAnimation 时代用；纯函数曲线由关键帧决定）
//   - **5 pet spring 曲线差异（mvp-pet-decision.md 第 4 节"招牌动作"对照）**：
//     * Pako 果冻弹：peak 1.1 / second 0.95 / damping 0.45（"夸张"）
//     * Mitu 抖毛  ：peak 1.05 / second 0.98 / damping 0.5（"温柔"）
//     * Mitu 蜷成球：peak 0.6 / second 1.05 / damping 0.6（"反向" — 先挤后弹）
//     * Zorp 触手甩：peak 1.15 / second 0.92 / damping 0.4（"乱甩" — 振幅大）
//     * Zorp 彩虹旋：peak 1.2 / second 0.9 / damping 0.3（"戏剧" — 弹性最强）
//
// Pako jelly-bounce 实测曲线（mvp-pet-decision.md 第 1 节）：
//   整只果冻化 + 肚子变粉红 + 呆滞眼眨一下 → 0.8 → 1.1 → 0.95 → 1.0
//   duration ~400ms（"果冻弹" 的解压 moment 节奏）
//   damping 0.45（弹性感：不够弹 = 僵硬，< 0.3 = 失控）
//
// 不做：
//   - 实际 CALayer / NSView 渲染（PetPanel 后续 plan）
//   - color / opacity / rotation 通道（只算 scale）
//   - 多个 spring 串接 / 重叠（后续 plan）

import Foundation

// MARK: - SpringParams

/// Spring 动画参数。
/// - duration: 总时长（秒）
/// - damping: 阻尼比 0..1（0 = 无限震荡，1 = 临界无震荡；Pako 0.45 是"会晃几下"）
/// - initialScale: 起始 scale（Pako jelly-bounce = 0.8，先被压扁）
/// - peakScale: 第一次过冲 scale（Pako = 1.1，超过正常大小）
/// - secondScale: 第二次回弹 scale（Pako = 0.95，反向过冲）
/// - restScale: 静止 scale（Pako = 1.0，回正）
public struct SpringParams: Equatable, Sendable, Hashable {
    public let duration: TimeInterval
    public let damping: Double
    public let initialScale: Double
    public let peakScale: Double
    public let secondScale: Double
    public let restScale: Double

    public init(
        duration: TimeInterval,
        damping: Double,
        initialScale: Double,
        peakScale: Double,
        secondScale: Double,
        restScale: Double
    ) {
        self.duration = duration
        self.damping = damping
        self.initialScale = initialScale
        self.peakScale = peakScale
        self.secondScale = secondScale
        self.restScale = restScale
    }
}

// MARK: - SpringAnimation

public enum SpringAnimation {

    /// Pako 招牌反应 "jelly-bounce" 的 spring 参数（果冻弹）。
    /// 来源：.private/product-design/mvp-pet-decision.md 第 1 节 + 5 通道 schema draft。
    public static func jellyBounceParams() -> SpringParams {
        return SpringParams(
            duration: 0.4,
            damping: 0.45,
            initialScale: 0.8,
            peakScale: 1.1,
            secondScale: 0.95,
            restScale: 1.0
        )
    }

    // MARK: - Mitu 招牌反应

    /// Mitu 招牌反应 "fur-shake-look-up"（点击 trigger）。
    /// 节奏：轻微抖动 + 抬头。duration 0.5s，damping 0.5（中等弹性），
    /// initial 1.0 → peak 1.05（轻微变大）→ second 0.98（轻微回缩）→ rest 1.0。
    /// 比 jelly-bounce 振幅小（peak -0.05 / second -0.03），符合"温柔"人设。
    /// 来源：.private/product-design/mvp-pet-decision.md 第 2 节 Mitu 招牌反应表
    /// + 任务 spec "Mitu fur-shake-look-up"。
    public static func mituFurShakeParams() -> SpringParams {
        return SpringParams(
            duration: 0.5,
            damping: 0.5,
            initialScale: 1.0,
            peakScale: 1.05,
            secondScale: 0.98,
            restScale: 1.0
        )
    }

    /// Mitu 招牌反应 "curl-into-ball"（长按 trigger）。
    /// 节奏：先挤成毛球（peak 0.6 远小于 1.0）再弹开（second 1.05 略大于 1.0），
    /// 再回正 rest 1.0。duration 1.0s 偏长，damping 0.6 收得快。
    /// peak/second 反向（一缩一弹）跟其他三个 pet 的"先变大再回"曲线不一样。
    /// 来源：.private/product-design/mvp-pet-decision.md 第 2 节 + 任务 spec。
    public static func mituCurlParams() -> SpringParams {
        return SpringParams(
            duration: 1.0,
            damping: 0.6,
            initialScale: 1.0,
            peakScale: 0.6,
            secondScale: 1.05,
            restScale: 1.0
        )
    }

    // MARK: - Zorp 招牌反应

    /// Zorp 招牌反应 "tentacle-slap"（点击 trigger）。
    /// 节奏：触手甩开，peak 1.15（最大，比 jelly-bounce 1.1 还夸张），
    /// second 0.92（明显回缩）→ rest 1.0。duration 0.4s 短促，damping 0.4 弹性强。
    /// 振幅大 → "乱甩" 的戏剧感。
    /// 来源：.private/product-design/mvp-pet-decision.md 第 2 节 Zorp + 任务 spec。
    public static func zorpTentacleSlapParams() -> SpringParams {
        return SpringParams(
            duration: 0.4,
            damping: 0.4,
            initialScale: 1.0,
            peakScale: 1.15,
            secondScale: 0.92,
            restScale: 1.0
        )
    }

    /// Zorp 招牌反应 "spin-rainbow"（双击 trigger）。
    /// 节奏：旋开（peak 1.2，比 tentacle-slap 1.15 还大）+ 收（second 0.9）→ rest 1.0。
    /// duration 1.0s 长，damping 0.3（最低，弹性最强、晃得最久）→ "彩虹色旋转" 节奏。
    /// 来源：.private/product-design/mvp-pet-decision.md 第 2 节 Zorp + 任务 spec。
    public static func zorpSpinParams() -> SpringParams {
        return SpringParams(
            duration: 1.0,
            damping: 0.3,
            initialScale: 1.0,
            peakScale: 1.2,
            secondScale: 0.9,
            restScale: 1.0
        )
    }

    /// 通用默认 spring（未知 spring-animation reaction 的 fallback）。
    /// 节奏比 jelly-bounce 略保守（peak 1.08，second 0.96），不会太夸张。
    public static func defaultSpringParams() -> SpringParams {
        return SpringParams(
            duration: 0.35,
            damping: 0.55,
            initialScale: 0.92,
            peakScale: 1.08,
            secondScale: 0.96,
            restScale: 1.0
        )
    }

    /// 按 reaction name 查 spring 参数。
    /// 表：5 个 pet 招牌反应（Pako × 1 + Mitu × 2 + Zorp × 2）—— P2-A3 加 Mitu + Zorp。
    /// 未知 name → nil（caller 决定是否走 defaultSpringParams）。
    public static func namedParams(_ name: String) -> SpringParams? {
        switch name {
        case "jelly-bounce":
            return jellyBounceParams()
        case "fur-shake-look-up":
            return mituFurShakeParams()
        case "curl-into-ball":
            return mituCurlParams()
        case "tentacle-slap":
            return zorpTentacleSlapParams()
        case "spin-rainbow":
            return zorpSpinParams()
        default:
            return nil
        }
    }

    /// 在 t 时刻的 scale 值（纯函数，便于单测）。
    ///
    /// 曲线分段（normalized p = t / duration）：
    ///   p in [0.00, 0.25] → initialScale  → peakScale
    ///   p in [0.25, 0.55] → peakScale     → secondScale
    ///   p in [0.55, 1.00] → secondScale   → restScale
    /// 段内 cubic ease-in-out：smoothstep(x) = x*x*(3 - 2x)
    ///
    /// 边界：
    ///   t ≤ 0        → initialScale
    ///   t ≥ duration → restScale
    ///   关键帧点 t 严格命中（cubic ease 在端点值为 0 / 1）
    public static func simulateScale(at t: TimeInterval, params: SpringParams) -> Double {
        if t <= 0 { return params.initialScale }
        if t >= params.duration { return params.restScale }

        // 防止 duration=0 / 负数导致的 NaN
        if params.duration <= 0 { return params.restScale }

        let p = t / params.duration  // 0..1

        // 关键帧 (normalized t, value)
        let k0: Double = 0.00
        let k1: Double = 0.25
        let k2: Double = 0.55
        let k3: Double = 1.00

        let v0 = params.initialScale
        let v1 = params.peakScale
        let v2 = params.secondScale
        let v3 = params.restScale

        let segmentEnd: Double
        let segmentStart: Double
        let valueStart: Double
        let valueEnd: Double

        if p < k1 {
            segmentStart = k0; segmentEnd = k1
            valueStart = v0; valueEnd = v1
        } else if p < k2 {
            segmentStart = k1; segmentEnd = k2
            valueStart = v1; valueEnd = v2
        } else {
            segmentStart = k2; segmentEnd = k3
            valueStart = v2; valueEnd = v3
        }

        let segLen = segmentEnd - segmentStart
        if segLen <= 0 {
            return valueEnd
        }
        let localP = (p - segmentStart) / segLen  // 0..1 within segment

        // smoothstep / cubic ease-in-out
        let eased = localP * localP * (3 - 2 * localP)
        return valueStart + (valueEnd - valueStart) * eased
    }
}

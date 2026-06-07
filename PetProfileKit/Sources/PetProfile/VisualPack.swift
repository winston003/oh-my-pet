// VisualPack.swift
// 视觉通道 — 5 个 state 图 + render_mode + 渲染相关元数据
// Schema 草案第 3 节
//

import Foundation

public struct VisualPack: Codable, Equatable, Sendable {
    public let renderMode: RenderMode
    public let supportedRenderModes: [RenderMode]
    public let transparentAlpha: Bool
    public let idleBreathing: Bool
    public let states: VisualStates

    enum CodingKeys: String, CodingKey {
        case renderMode = "render_mode"
        case supportedRenderModes = "supported_render_modes"
        case transparentAlpha = "transparent_alpha"
        case idleBreathing = "idle_breathing"
        case states
    }

    public init(
        renderMode: RenderMode,
        supportedRenderModes: [RenderMode]? = nil,
        transparentAlpha: Bool = true,
        idleBreathing: Bool = true,
        states: VisualStates
    ) {
        self.renderMode = renderMode
        self.supportedRenderModes = supportedRenderModes ?? [renderMode]
        self.transparentAlpha = transparentAlpha
        self.idleBreathing = idleBreathing
        self.states = states
    }
}

public enum RenderMode: String, Codable, Equatable, Sendable, CaseIterable {
    case staticImage = "static-image"
    case sprite = "sprite"
    case live2d = "live2d"
    case spine = "spine"
    case video = "video"
}

public struct VisualStates: Codable, Equatable, Sendable {
    public let idle: String
    public let focus: String
    public let happy: String
    public let tired: String
    public let celebrate: String

    public init(idle: String, focus: String, happy: String, tired: String, celebrate: String) {
        self.idle = idle
        self.focus = focus
        self.happy = happy
        self.tired = tired
        self.celebrate = celebrate
    }
}

import SwiftUI

extension Color {
    // Dark mode background (primary)
    static let hudBackground = Color(hue: 260/360, saturation: 0.045, brightness: 0.11)
    static let hudCard = Color(hue: 260/360, saturation: 0.055, brightness: 0.145)
    static let hudCardElevated = Color(hue: 260/360, saturation: 0.06, brightness: 0.17)
    static let hudBorder = Color.white.opacity(0.10)

    // Default status colors (used in RELEASE mode)
    private static let defaultStatusReady = Color(hue: 0.329, saturation: 1.00, brightness: 1.00)
    private static let defaultStatusWorking = Color(hue: 0.103, saturation: 1.00, brightness: 1.00)
    private static let defaultStatusWaiting = Color(hue: 0.026, saturation: 0.58, brightness: 1.00)
    private static let defaultStatusCompacting = Color(hue: 0.670, saturation: 0.50, brightness: 1.00)
    private static let defaultStatusIdle = Color.white.opacity(0.40)

    // Status colors - tunable in DEBUG mode
    static var statusReady: Color {
        #if DEBUG
        let config = GlassConfig.shared
        return Color(hue: config.statusReadyHue, saturation: config.statusReadySaturation, brightness: config.statusReadyBrightness)
        #else
        return defaultStatusReady
        #endif
    }

    static var statusWorking: Color {
        #if DEBUG
        let config = GlassConfig.shared
        return Color(hue: config.statusWorkingHue, saturation: config.statusWorkingSaturation, brightness: config.statusWorkingBrightness)
        #else
        return defaultStatusWorking
        #endif
    }

    static var statusWaiting: Color {
        #if DEBUG
        let config = GlassConfig.shared
        return Color(hue: config.statusWaitingHue, saturation: config.statusWaitingSaturation, brightness: config.statusWaitingBrightness)
        #else
        return defaultStatusWaiting
        #endif
    }

    static var statusCompacting: Color {
        #if DEBUG
        let config = GlassConfig.shared
        return Color(hue: config.statusCompactingHue, saturation: config.statusCompactingSaturation, brightness: config.statusCompactingBrightness)
        #else
        return defaultStatusCompacting
        #endif
    }

    static var statusIdle: Color {
        #if DEBUG
        let config = GlassConfig.shared
        return Color.white.opacity(config.statusIdleOpacity)
        #else
        return defaultStatusIdle
        #endif
    }

    // Flash colors (for state change animations)
    static var flashReady: Color { statusReady.opacity(0.25) }
    static var flashWaiting: Color { statusWaiting.opacity(0.25) }
    static var flashCompacting: Color { statusCompacting.opacity(0.20) }

    // Accent
    static let hudAccent = Color(hue: 24/360, saturation: 0.85, brightness: 0.95)
    static let hudAccentDark = Color(hue: 24/360, saturation: 0.90, brightness: 0.75)

    // Detail view section accent
    static let sectionAccent = Color(hue: 24/360, saturation: 0.70, brightness: 0.85)

    static func flashColor(for state: SessionState) -> Color {
        switch state {
        case .ready:
            return statusReady
        case .waiting:
            return statusWaiting
        case .compacting:
            return statusCompacting
        default:
            return .clear
        }
    }

    static func statusColor(for state: SessionState) -> Color {
        switch state {
        case .ready: return statusReady
        case .working: return statusWorking
        case .waiting: return statusWaiting
        case .compacting: return statusCompacting
        case .idle: return statusIdle
        }
    }
}

struct HudGradients {
    static let accent = LinearGradient(
        colors: [Color.hudAccent, Color.hudAccentDark],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardHighlight = LinearGradient(
        colors: [Color.white.opacity(0.08), Color.white.opacity(0.02)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let cardBorder = LinearGradient(
        colors: [Color.white.opacity(0.15), Color.white.opacity(0.05)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func glowGradient(for color: Color) -> RadialGradient {
        RadialGradient(
            colors: [color.opacity(0.4), color.opacity(0.0)],
            center: .center,
            startRadius: 0,
            endRadius: 20
        )
    }
}

import AppKit
import SwiftUI

extension Color {
    // Dark mode background (primary)
    static let hudBackground = Color(hue: 260/360, saturation: 0.045, brightness: 0.11)
    static let hudCard = Color(hue: 260/360, saturation: 0.055, brightness: 0.145)
    static let hudCardElevated = Color(hue: 260/360, saturation: 0.06, brightness: 0.17)

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

    // Accent - uses system accent color
    static var hudAccent: Color { Color.accentColor }
    static var hudAccentDark: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.3, of: .black) ?? NSColor.controlAccentColor)
    }

    // Detail view section accent
    static var sectionAccent: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.15, of: .black) ?? NSColor.controlAccentColor)
    }

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

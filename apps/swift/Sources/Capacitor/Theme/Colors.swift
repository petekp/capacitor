import AppKit
import SwiftUI

extension Color {
    /// Brand — oklch(0.8647 0.2886 150.35) in Display P3
    /// Out-of-sRGB-gamut green; all Apple Silicon Macs support P3.
    static let brand = Color(.displayP3, red: 0.302, green: 0.997, blue: 0.450)

    // Dark mode background (primary)
    static let hudBackground = Color(hue: 260 / 360, saturation: 0.045, brightness: 0.11)
    static let hudCard = Color(hue: 260 / 360, saturation: 0.055, brightness: 0.145)
    static let hudCardElevated = Color(hue: 260 / 360, saturation: 0.06, brightness: 0.17)

    /// Status colors - driven by GlassConfig
    static var statusReady: Color {
        #if DEBUG
            let config = GlassConfig.shared
            return Color(hue: config.statusReadyHue, saturation: config.statusReadySaturation, brightness: config.statusReadyBrightness)
        #else
            return .brand
        #endif
    }

    static var statusWorking: Color {
        let config = GlassConfig.shared
        return Color(hue: config.statusWorkingHue, saturation: config.statusWorkingSaturation, brightness: config.statusWorkingBrightness)
    }

    static var statusWaiting: Color {
        let config = GlassConfig.shared
        return Color(hue: config.statusWaitingHue, saturation: config.statusWaitingSaturation, brightness: config.statusWaitingBrightness)
    }

    static var statusCompacting: Color {
        let config = GlassConfig.shared
        return Color(hue: config.statusCompactingHue, saturation: config.statusCompactingSaturation, brightness: config.statusCompactingBrightness)
    }

    static var statusIdle: Color {
        let config = GlassConfig.shared
        return Color.white.opacity(config.statusIdleOpacity)
    }

    /// Accent - uses system accent color
    static var hudAccent: Color {
        Color.accentColor
    }

    static var hudAccentDark: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.3, of: .black) ?? NSColor.controlAccentColor)
    }

    /// Detail view section accent
    static var sectionAccent: Color {
        Color(nsColor: NSColor.controlAccentColor.blended(withFraction: 0.15, of: .black) ?? NSColor.controlAccentColor)
    }

    static func flashColor(for state: SessionState) -> Color {
        switch state {
        case .ready:
            statusReady
        case .waiting:
            statusWaiting
        case .compacting:
            statusCompacting
        default:
            .clear
        }
    }

    static func statusColor(for state: SessionState) -> Color {
        switch state {
        case .ready: statusReady
        case .working: statusWorking
        case .waiting: statusWaiting
        case .compacting: statusCompacting
        case .idle: statusIdle
        }
    }
}

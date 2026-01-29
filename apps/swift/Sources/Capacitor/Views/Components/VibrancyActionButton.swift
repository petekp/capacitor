import AppKit
import SwiftUI

// MARK: - Preference Key for Frame Tracking

struct ButtonFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

// MARK: - Vibrancy Action Button

/// Rounded button with native macOS vibrancy and entrance animation.
/// Commonly used for hover-revealed action buttons on cards.
struct VibrancyActionButton: View {
    let icon: String
    let action: (CGRect) -> Void
    var isVisible: Bool = true
    var entranceDelay: Double = 0
    var style: Style = .normal

    enum Style {
        case normal
        case compact
    }

    @State private var isHovered = false
    @State private var buttonFrame: CGRect = .zero

    private var size: CGFloat {
        style == .compact ? 32 : 40
    }

    private var iconSize: CGFloat {
        style == .compact ? 13 : 15
    }

    private var entranceAnimation: Animation {
        .spring(response: 0.25, dampingFraction: 0.7)
            .delay(entranceDelay)
    }

    var body: some View {
        Button(action: { action(buttonFrame) }) {
            ZStack {
                // Vibrancy background (only on hover)
                if isHovered {
                    Circle()
                        .fill(.clear)
                        .background(
                            VibrancyView(
                                material: .hudWindow,
                                blendingMode: .behindWindow,
                                isEmphasized: true,
                                forceDarkAppearance: true
                            )
                        )
                        .clipShape(Circle())

                    // Light tint overlay
                    Circle()
                        .fill(Color.black.opacity(0.15))

                    // Subtle border
                    Circle()
                        .strokeBorder(
                            Color.white.opacity(0.15),
                            lineWidth: 0.5
                        )
                }

                // Icon
                Image(systemName: icon)
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white.opacity(isHovered ? 0.95 : 0.5))
            }
            .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .scaleEffect(isVisible ? 1.0 : 0.9)
        .blur(radius: isVisible ? 0 : 4)
        .opacity(isVisible ? 1.0 : 0)
        .animation(entranceAnimation, value: isVisible)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ButtonFramePreferenceKey.self,
                    value: geo.frame(in: .named("contentView"))
                )
            }
        )
        .onPreferenceChange(ButtonFramePreferenceKey.self) { frame in
            buttonFrame = frame
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

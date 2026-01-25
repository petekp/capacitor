import AppKit
import SwiftUI

/// Brand-colored logomark with soft radial glow and drag-to-spin interaction.
/// Used on setup and empty-state screens for a consistent branded presence.
struct BrandLogomark: View {
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var size: CGFloat = 40

    @State private var rotation: Double = 0
    @State private var dragBase: Double = 0
    @State private var isHovered = false

    private static let cachedImage: NSImage? = {
        guard let url = ResourceBundle.url(forResource: "logomark", withExtension: "pdf") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let nsImage = Self.cachedImage {
            Image(nsImage: nsImage)
                .renderingMode(.template)
                .resizable()
                .frame(width: size, height: size)
                .foregroundStyle(Color.brand.opacity(isHovered ? 0.9 : 0.7))
                .rotationEffect(.degrees(rotation))
                .scaleEffect(isHovered ? 1.08 : 1.0)
                .animation(
                    reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.25, dampingFraction: 0.6),
                    value: isHovered,
                )
                .background {
                    Circle()
                        .fill(Color.brand.opacity(isHovered ? 0.12 : 0.08))
                        .blur(radius: size * 0.6)
                        .scaleEffect(1.8)
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let delta = value.translation.height * 0.5
                            rotation = dragBase + delta
                        }
                        .onEnded { _ in
                            dragBase = rotation
                        },
                )
                .onHover { hovering in
                    isHovered = hovering
                }
                .preventWindowDrag()
                .help("Give it a spin")
                .accessibilityLabel("Capacitor logomark")
        } else {
            Image(systemName: "sparkles")
                .font(.system(size: size))
                .foregroundStyle(Color.brand.opacity(0.7))
        }
    }
}

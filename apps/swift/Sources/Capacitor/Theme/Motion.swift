import SwiftUI

struct AppMotion {
    static let reducedMotionFallback = Animation.easeInOut(duration: 0.15)
}

extension EnvironmentValues {
    @Entry var prefersReducedMotion: Bool = false
}

struct ReduceMotionReader: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.environment(\.prefersReducedMotion, reduceMotion)
    }
}

extension View {
    func readReduceMotion() -> some View {
        modifier(ReduceMotionReader())
    }
}

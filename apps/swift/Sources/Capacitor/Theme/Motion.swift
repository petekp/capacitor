import SwiftUI

struct AppMotion {
    static let reducedMotionFallback = Animation.easeInOut(duration: 0.15)
}

struct ReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var prefersReducedMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
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

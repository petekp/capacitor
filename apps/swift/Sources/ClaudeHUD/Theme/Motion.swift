import SwiftUI

struct AppMotion {
    static let fastInteraction = Animation.spring(response: 0.15, dampingFraction: 0.7)
    static let standard = Animation.spring(response: 0.35, dampingFraction: 0.8)
    static let emphasize = Animation.bouncy(duration: 0.45)
    static let subtle = Animation.easeOut(duration: 0.2)
    static let tabSwitch = Animation.spring(response: 0.25, dampingFraction: 0.8)
    static let cardHover = Animation.easeOut(duration: 0.2)
    static let flash = Animation.easeOut(duration: 1.3)
    static let navigation = Animation.spring(response: 0.35, dampingFraction: 0.86)

    static let reducedMotionFallback = Animation.easeInOut(duration: 0.15)
    static let reducedMotionNone = Animation.linear(duration: 0.01)
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

    func safeAnimation(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? AppMotion.reducedMotionFallback : animation
    }
}

struct AccessibilityAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.prefersReducedMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? AppMotion.reducedMotionFallback : animation, value: value)
    }
}

extension View {
    func accessibilityAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(AccessibilityAnimationModifier(animation: animation, value: value))
    }
}

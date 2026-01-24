import AppKit
import SwiftUI

extension View {
    func cardStyling(
        isHovered: Bool,
        isReady: Bool,
        isWaiting: Bool = false,
        isWorking: Bool = false,
        isActive: Bool,
        flashState: SessionState?,
        flashOpacity: Double,
        floatingMode: Bool,
        floatingCardBackground: some View,
        solidCardBackground: some View,
        animationSeed: String,
        cornerRadius: CGFloat = 12,
        layoutMode: LayoutMode = .vertical,
        isPressed: Bool = false
    ) -> some View {
        self
            .background {
                ZStack {
                    if floatingMode {
                        floatingCardBackground
                            .id(GlassConfig.shared.cardConfigHash)
                    } else {
                        solidCardBackground
                    }

                    if isWorking {
                        WorkingStripeOverlay(layoutMode: layoutMode)
                            .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                    .opacity(flashOpacity)
            )
            .overlay {
                ZStack {
                    if isActive {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(
                                Color.white.opacity(0.3),
                                lineWidth: 3
                            )
                            .blur(radius: 4)

                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(
                                Color.white.opacity(0.8),
                                lineWidth: 1.5
                            )
                    }
                }
            }
            .overlay {
                if isReady {
                    ReadyAmbientGlow(layoutMode: layoutMode)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .overlay {
                if isReady {
                    ReadyBorderGlow(seed: animationSeed, cornerRadius: cornerRadius, layoutMode: layoutMode)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .overlay {
                if isWaiting {
                    WaitingAmbientPulse(layoutMode: layoutMode)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .overlay {
                if isWaiting {
                    WaitingBorderPulse(seed: animationSeed, cornerRadius: cornerRadius, layoutMode: layoutMode)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .overlay {
                if isWorking {
                    WorkingBorderGlow(seed: animationSeed, cornerRadius: cornerRadius, layoutMode: layoutMode)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .shadow(
                color: .black.opacity(shadowOpacity(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode)),
                radius: shadowRadius(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode),
                y: shadowY(isHovered: isHovered, isPressed: isPressed, floatingMode: floatingMode, layoutMode: layoutMode)
            )
    }

    func cardInteractions(
        isHovered: Binding<Bool>,
        onTap: @escaping () -> Void,
        onDragStarted: (() -> NSItemProvider)?
    ) -> some View {
        self
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                onTap()
                return .handled
            }
            .onKeyPress(.space) {
                onTap()
                return .handled
            }
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) {
                    isHovered.wrappedValue = hovering
                }
            }
            .onDrag {
                _ = onDragStarted?()
                return NSItemProvider(object: "" as NSString)
            } preview: {
                Color.clear.frame(width: 1, height: 1)
            }
    }

    func cardLifecycleHandlers(
        flashState: SessionState?,
        sessionState: ProjectSessionState?,
        currentState: SessionState?,
        previousState: Binding<SessionState?>,
        lastChimeTime: Binding<Date?>,
        flashOpacity: Binding<Double>,
        chimeCooldown: TimeInterval,
        glassConfig: GlassConfig?
    ) -> some View {
        self
            .animation(.easeInOut(duration: 0.4), value: sessionState?.state)
            .onChange(of: flashState) { _, newValue in
                guard newValue != nil else { return }
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity.wrappedValue = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity.wrappedValue = 0
                }
            }
            .onChange(of: sessionState?.state) { oldValue, newValue in
                if glassConfig?.previewState != Optional<PreviewState>.none { return }

                if newValue == .ready && oldValue != .ready && oldValue != nil {
                    let now = Date()
                    let shouldPlayChime = lastChimeTime.wrappedValue.map { now.timeIntervalSince($0) >= chimeCooldown } ?? true
                    if shouldPlayChime {
                        lastChimeTime.wrappedValue = now
                        ReadyChime.shared.play()
                    }
                }
                previousState.wrappedValue = newValue
            }
            .onChange(of: glassConfig?.previewState) { oldValue, newValue in
                if newValue == .ready && oldValue != .ready {
                    ReadyChime.shared.play()
                }
            }
            .onAppear {
                previousState.wrappedValue = sessionState?.state
            }
    }

    func preventWindowDrag() -> some View {
        WindowDragPreventer { self }
    }

    func windowDraggable() -> some View {
        WindowDragHandle { self }
    }
}

// MARK: - Shadow Helpers

private func shadowOpacity(isHovered: Bool, isPressed: Bool, floatingMode: Bool, layoutMode: LayoutMode) -> Double {
    guard !floatingMode else { return 0.25 }
    let config = GlassConfig.shared
    if isPressed {
        return config.cardPressedShadowOpacity
    } else if isHovered {
        return config.cardHoverShadowOpacity
    }
    return config.cardIdleShadowOpacity
}

private func shadowRadius(isHovered: Bool, isPressed: Bool, floatingMode: Bool, layoutMode: LayoutMode) -> CGFloat {
    guard !floatingMode else { return 8 }
    let config = GlassConfig.shared
    if isPressed {
        return config.cardPressedShadowRadius
    } else if isHovered {
        return config.cardHoverShadowRadius
    }
    return config.cardIdleShadowRadius
}

private func shadowY(isHovered: Bool, isPressed: Bool, floatingMode: Bool, layoutMode: LayoutMode) -> CGFloat {
    guard !floatingMode else { return 3 }
    let config = GlassConfig.shared
    if isPressed {
        return config.cardPressedShadowY
    } else if isHovered {
        return config.cardHoverShadowY
    }
    return config.cardIdleShadowY
}

// MARK: - Window Drag Handling

struct WindowDragPreventer<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> NonDraggableHostingView<Content> {
        NonDraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: NonDraggableHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}

struct WindowDragHandle<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    func makeNSView(context: Context) -> DraggableHostingView<Content> {
        DraggableHostingView(rootView: content)
    }

    func updateNSView(_ nsView: DraggableHostingView<Content>, context: Context) {
        nsView.rootView = content
    }
}

final class NonDraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { false }
}

final class DraggableHostingView<Content: View>: NSHostingView<Content> {
    override var mouseDownCanMoveWindow: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

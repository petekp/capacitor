import AppKit
import SwiftUI

extension View {
    func cardStyling(
        isHovered: Bool,
        isReady: Bool,
        isActive: Bool,
        flashState: SessionState?,
        flashOpacity: Double,
        floatingMode: Bool,
        floatingCardBackground: some View,
        solidCardBackground: some View,
        animationSeed: String
    ) -> some View {
        self
            .background {
                if floatingMode {
                    floatingCardBackground
                        #if DEBUG
                        .id(GlassConfig.shared.cardConfigHash)
                        #endif
                } else {
                    solidCardBackground
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                    .opacity(flashOpacity)
            )
            .overlay {
                if isActive {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                Color.white.opacity(0.3),
                                lineWidth: 3
                            )
                            .blur(radius: 4)

                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                Color.white.opacity(0.8),
                                lineWidth: 1.5
                            )
                    }
                    .transition(.opacity.animation(.easeOut(duration: 0.2)))
                }
            }
            .overlay {
                if isReady {
                    ReadyAmbientGlow()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .overlay {
                if isReady {
                    ReadyBorderGlow(seed: animationSeed)
                        .transition(.opacity.animation(.easeInOut(duration: 0.4)))
                }
            }
            .shadow(
                color: floatingMode ? .black.opacity(0.25) : (isHovered ? .black.opacity(0.2) : .black.opacity(0.08)),
                radius: floatingMode ? 8 : (isHovered ? 12 : 4),
                y: floatingMode ? 3 : (isHovered ? 4 : 2)
            )
            .scaleEffect(isHovered ? 0.99 : 1.0)
            .animation(.easeOut(duration: 0.2), value: isHovered)
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

    #if DEBUG
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
    #else
    func cardLifecycleHandlers(
        flashState: SessionState?,
        sessionState: ProjectSessionState?,
        currentState: SessionState?,
        previousState: Binding<SessionState?>,
        lastChimeTime: Binding<Date?>,
        flashOpacity: Binding<Double>,
        chimeCooldown: TimeInterval,
        glassConfig: Any?
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
            .onAppear {
                previousState.wrappedValue = sessionState?.state
            }
    }
    #endif
}

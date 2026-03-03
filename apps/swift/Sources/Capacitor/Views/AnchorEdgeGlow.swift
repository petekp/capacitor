import SwiftUI

// MARK: - Anchor Edge Glow

/// Renders a glowing border on the HUD edge facing the anchored target window.
///
/// Three modes:
/// - **Approaching**: opacity scales with proximity fraction (0 → 1) as HUD nears target
/// - **Active anchor**: one-shot pulse on first attach, quick fade-in on wake from dormant
/// - **Dormant anchor**: glow fades out when target app is backgrounded
struct AnchorEdgeGlow: View {
    let controller: WindowAnchoringController
    @Environment(\.prefersReducedMotion) private var reduceMotion

    @State private var pulseOpacity: CGFloat = 0
    @State private var steadyOpacity: CGFloat = 0
    /// Tracks the last-known anchor edge so the glow stays correct during fade-out.
    @State private var anchoredEdge: AnchorEdge?

    var body: some View {
        let active = controller.state.isActivelyAnchored
        let hasAnchor = controller.state.isAnchored
        let edge = controller.state.descriptor?.edge
        let proximity = controller.proximityFeedback

        GeometryReader { geometry in
            ZStack {
                // Layer 1: Proximity-based approaching glow (pre-snap)
                if !hasAnchor, let proximity {
                    approachingGlow(
                        anchorEdge: proximity.edge,
                        fraction: proximity.fraction,
                        size: geometry.size,
                    )
                }

                // Layer 2: Anchored glow (pulse + steady state)
                if let displayEdge = anchoredEdge {
                    anchoredGlow(edge: displayEdge, size: geometry.size)
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: active) { wasActive, isActive in
            if isActive, !wasActive {
                handleActivate(edge: edge)
            } else if !isActive, wasActive {
                handleFadeOut()
            }
        }
        .onChange(of: hasAnchor) { wasAnchored, isAnchored in
            // Full detach — clear edge after fade animation completes
            if !isAnchored, wasAnchored {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if !controller.state.isAnchored {
                        anchoredEdge = nil
                    }
                }
            }
        }
        .onChange(of: edge) { _, newEdge in
            if active, let newEdge {
                anchoredEdge = newEdge
            }
        }
    }

    // MARK: - Approaching Glow

    private func approachingGlow(anchorEdge: AnchorEdge, fraction: CGFloat, size: CGSize) -> some View {
        let glowEdge = connectedEdge(for: anchorEdge)
        let opacity = Double(fraction)

        return Group {
            sharpLine(edge: glowEdge, size: size)
            bloomGradient(edge: glowEdge, size: size)
        }
        .opacity(opacity)
        .blendMode(.plusLighter)
        .animation(.easeOut(duration: 0.08), value: fraction)
    }

    // MARK: - Anchored Glow

    @ViewBuilder
    private func anchoredGlow(edge: AnchorEdge, size: CGSize) -> some View {
        let glowEdge = connectedEdge(for: edge)

        ZStack {
            // Pulse layer (one-shot attach animation)
            pulseGradient(edge: glowEdge, size: size)
                .opacity(pulseOpacity)

            // Steady-state layers
            Group {
                sharpLine(edge: glowEdge, size: size)
                bloomGradient(edge: glowEdge, size: size)
            }
            .opacity(steadyOpacity)
        }
        .blendMode(.plusLighter)
    }

    // MARK: - Shared Glow Primitives

    /// The pulse gradient that radiates inward from the connected edge on attach.
    private func pulseGradient(edge: Edge, size: CGSize) -> some View {
        let gradient = LinearGradient(
            colors: [Color.white.opacity(0.6), Color.white.opacity(0)],
            startPoint: unitPoint(for: edge),
            endPoint: unitPoint(for: edge.opposite),
        )
        return Rectangle()
            .fill(gradient)
            .frame(
                width: edge.isHorizontal ? 24 : size.width,
                height: edge.isHorizontal ? size.height : 24,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: edge))
    }

    /// The thin bright line on the connected edge (1px, white at ~0.3 opacity).
    private func sharpLine(edge: Edge, size: CGSize) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.3))
            .frame(
                width: edge.isHorizontal ? 1 : size.width,
                height: edge.isHorizontal ? size.height : 1,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: edge))
    }

    /// Soft bloom behind the sharp line (8px gradient, white at ~0.1 opacity).
    private func bloomGradient(edge: Edge, size: CGSize) -> some View {
        let gradient = LinearGradient(
            colors: [Color.white.opacity(0.1), Color.white.opacity(0)],
            startPoint: unitPoint(for: edge),
            endPoint: unitPoint(for: edge.opposite),
        )
        return Rectangle()
            .fill(gradient)
            .frame(
                width: edge.isHorizontal ? 8 : size.width,
                height: edge.isHorizontal ? size.height : 8,
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment(for: edge))
    }

    // MARK: - State Transitions

    /// Called when transitioning to actively anchored.
    /// First attach shows a pulse; wake from dormant just fades the steady glow back in.
    private func handleActivate(edge: AnchorEdge?) {
        guard let edge else { return }
        let isWake = anchoredEdge != nil
        anchoredEdge = edge

        if isWake || reduceMotion {
            // Wake or reduced-motion: snap steady glow on quickly
            withAnimation(.easeOut(duration: 0.12)) {
                steadyOpacity = 1
            }
        } else {
            // First attach: one-shot pulse then settle
            pulseOpacity = 0
            withAnimation(.spring(response: 0.15, dampingFraction: 0.7)) {
                pulseOpacity = 1
            }
            withAnimation(.easeOut(duration: 0.15).delay(0.15)) {
                pulseOpacity = 0
                steadyOpacity = 1
            }
        }
    }

    /// Called when transitioning away from actively anchored (sleep or detach).
    private func handleFadeOut() {
        withAnimation(.easeOut(duration: 0.12)) {
            pulseOpacity = 0
            steadyOpacity = 0
        }
    }

    // MARK: - Edge Mapping

    /// Maps the anchor edge (where the HUD sits relative to the target) to the
    /// HUD edge that faces the target (i.e. the "connected" edge that glows).
    private func connectedEdge(for anchorEdge: AnchorEdge) -> Edge {
        switch anchorEdge {
        case .leading: .trailing // HUD is left of target → right edge glows
        case .trailing: .leading // HUD is right of target → left edge glows
        case .top: .bottom // HUD is above target → bottom edge glows
        case .bottom: .top // HUD is below target → top edge glows
        }
    }

    private func unitPoint(for edge: Edge) -> UnitPoint {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }

    private func alignment(for edge: Edge) -> Alignment {
        switch edge {
        case .leading: .leading
        case .trailing: .trailing
        case .top: .top
        case .bottom: .bottom
        }
    }
}

// MARK: - Edge Helpers

private extension Edge {
    var opposite: Edge {
        switch self {
        case .top: .bottom
        case .bottom: .top
        case .leading: .trailing
        case .trailing: .leading
        }
    }

    var isHorizontal: Bool {
        self == .leading || self == .trailing
    }
}

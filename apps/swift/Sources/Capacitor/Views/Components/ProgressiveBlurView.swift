// ProgressiveBlurView.swift
//
// Creates a progressive blur effect where the blur gradually fades in from
// transparent to full intensity. Uses NSVisualEffectView with a gradient mask.
//
// Key difference from standard blur:
// - Standard blur + gradient mask: fades OPACITY of uniform blur
// - True progressive blur: varies BLUR RADIUS (requires Metal - see Glur library)
// This implementation uses the opacity-fade approach, which is lightweight and
// matches system vibrancy but doesn't perfectly match Apple's Control Center effect.
//
// Usage:
//   ProgressiveBlurView(direction: .up, height: 60)
//     .allowsHitTesting(false)  // Important: let clicks pass through
//
// The blur extends in the specified direction from the edge of the view.

import SwiftUI
import AppKit

/// Direction the blur fades OUT toward (where it becomes transparent)
enum BlurDirection {
    case up      // Blur is solid at bottom, fades to transparent going up (for footer overlays)
    case down    // Blur is solid at top, fades to transparent going down (for header overlays)
    case left    // Blur is solid at right, fades to transparent going left
    case right   // Blur is solid at left, fades to transparent going right

    /// Where the gradient is CLEAR (blur hidden)
    var clearPoint: UnitPoint {
        switch self {
        case .up: return .top
        case .down: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }

    /// Where the gradient is OPAQUE (blur visible)
    var opaquePoint: UnitPoint {
        switch self {
        case .up: return .bottom
        case .down: return .top
        case .left: return .trailing
        case .right: return .leading
        }
    }
}

struct ProgressiveBlurView: View {
    let direction: BlurDirection
    let blurHeight: CGFloat
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    /// Creates a progressive blur effect.
    /// - Parameters:
    ///   - direction: Direction the blur fades toward (default: .up for footer use)
    ///   - height: Height/width of the blur gradient zone
    ///   - material: NSVisualEffectView material (default: .hudWindow)
    ///   - blendingMode: How the blur composites (default: .behindWindow)
    init(
        direction: BlurDirection = .up,
        height: CGFloat = 60,
        material: NSVisualEffectView.Material = .hudWindow,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.direction = direction
        self.blurHeight = height
        self.material = material
        self.blendingMode = blendingMode
    }

    var body: some View {
        VibrancyView(
            material: material,
            blendingMode: blendingMode,
            isEmphasized: false,
            forceDarkAppearance: true
        )
        .mask(
            LinearGradient(
                colors: [.clear, .white],
                startPoint: direction.clearPoint,
                endPoint: direction.opaquePoint
            )
        )
        .frame(height: direction == .up || direction == .down ? blurHeight : nil)
        .frame(width: direction == .left || direction == .right ? blurHeight : nil)
    }
}

// MARK: - View Modifier for Easy Application

extension View {
    /// Adds a progressive blur overlay at the specified edge.
    /// Useful for scroll views where content should fade into a blurred footer/header.
    func progressiveBlur(
        edge: Edge,
        height: CGFloat = 60,
        material: NSVisualEffectView.Material = .hudWindow
    ) -> some View {
        self.overlay(alignment: edge.alignment) {
            ProgressiveBlurView(
                direction: edge.blurDirection,
                height: height,
                material: material
            )
            .allowsHitTesting(false)
        }
    }
}

private extension Edge {
    var alignment: Alignment {
        switch self {
        case .top: return .top
        case .bottom: return .bottom
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }

    var blurDirection: BlurDirection {
        switch self {
        case .top: return .down
        case .bottom: return .up
        case .leading: return .left
        case .trailing: return .right
        }
    }
}

#Preview("Progressive Blur - Footer") {
    ZStack {
        // Simulated scrolling content
        VStack(spacing: 8) {
            ForEach(0..<20) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.blue.opacity(0.3))
                    .frame(height: 44)
                    .overlay(Text("Item \(i)").foregroundColor(.white))
            }
        }
        .padding()

        // Footer with progressive blur
        VStack {
            Spacer()

            ProgressiveBlurView(direction: .up, height: 80)
                .allowsHitTesting(false)

            HStack {
                Text("Footer Content")
                    .foregroundColor(.white)
                Spacer()
            }
            .padding()
            .background(Color.black.opacity(0.3))
        }
    }
    .frame(width: 300, height: 400)
    .background(Color.black)
}

#Preview("Progressive Blur - Header") {
    ZStack {
        VStack(spacing: 8) {
            ForEach(0..<20) { i in
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.green.opacity(0.3))
                    .frame(height: 44)
            }
        }
        .padding()

        VStack {
            HStack {
                Text("Header")
                    .foregroundColor(.white)
                Spacer()
            }
            .padding()
            .background(Color.black.opacity(0.3))

            ProgressiveBlurView(direction: .down, height: 60)
                .allowsHitTesting(false)

            Spacer()
        }
    }
    .frame(width: 300, height: 400)
    .background(Color.black)
}

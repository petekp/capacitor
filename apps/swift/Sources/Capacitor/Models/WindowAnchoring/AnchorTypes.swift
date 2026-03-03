import AppKit

// MARK: - Target Window Identity

struct TargetWindowIdentity: Equatable, Hashable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let windowName: String?
}

// MARK: - Anchor Edge

enum AnchorEdge: String, CaseIterable {
    case leading
    case trailing
    case top
    case bottom
}

// MARK: - Anchor Descriptor

struct AnchorDescriptor: Equatable {
    let target: TargetWindowIdentity
    let edge: AnchorEdge
    let gap: CGFloat
    let offset: CGFloat

    /// Pure geometry: compute the HUD frame given target bounds and HUD size.
    /// All coordinates are in AppKit screen space (origin bottom-left).
    func computeHUDFrame(targetBounds: CGRect, hudSize: CGSize) -> CGRect {
        let origin = switch edge {
        case .leading:
            CGPoint(
                x: targetBounds.minX - hudSize.width - gap,
                y: targetBounds.maxY - hudSize.height + offset,
            )
        case .trailing:
            CGPoint(
                x: targetBounds.maxX + gap,
                y: targetBounds.maxY - hudSize.height + offset,
            )
        case .top:
            CGPoint(
                x: targetBounds.minX + offset,
                y: targetBounds.maxY + gap,
            )
        case .bottom:
            CGPoint(
                x: targetBounds.minX + offset,
                y: targetBounds.minY - hudSize.height - gap,
            )
        }
        return CGRect(origin: origin, size: hudSize)
    }
}

// MARK: - Anchoring State

enum AnchoringState: Equatable {
    case idle
    case anchored(AnchorDescriptor)
    case trackingDrag(AnchorDescriptor, cursorDelta: CGSize)
    case trackingMotion(AnchorDescriptor, ticksSinceLastMove: Int)

    var descriptor: AnchorDescriptor? {
        switch self {
        case .idle:
            nil
        case let .anchored(d), let .trackingDrag(d, _), let .trackingMotion(d, _):
            d
        }
    }

    var isAnchored: Bool {
        if case .idle = self { return false }
        return true
    }
}

// MARK: - Snap Candidate

struct SnapCandidate: Equatable {
    let identity: TargetWindowIdentity
    let edge: AnchorEdge
    let hudFrame: CGRect
    let distance: CGFloat
}

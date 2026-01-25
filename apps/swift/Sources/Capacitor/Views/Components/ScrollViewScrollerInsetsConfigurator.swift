import AppKit
import SwiftUI

// MARK: - Trackless Scroller

/// NSScroller subclass that hides the knob slot (track background).
/// Only the knob (thumb) is drawn — the dark track strip that appears on hover is suppressed.
///
/// Per the NSScroller.h contract, overlay-compatible subclasses MUST customize
/// drawing via `-drawKnob` and `-drawKnobSlotInRect:highlight:` (not `-drawRect:`),
/// so AppKit can independently fade the knob and track for overlay animations.
final class TracklessScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool {
        self == TracklessScroller.self
    }

    override func drawKnobSlot(in _: NSRect, highlight _: Bool) {
        // No-op: suppresses the track background while preserving the knob.
    }
}

// MARK: - Scroll View Configurator

struct ScrollViewScrollerInsetsConfigurator: NSViewRepresentable {
    let topInset: CGFloat
    let bottomInset: CGFloat
    var hideTrack: Bool = false

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(from: view, topInset: topInset, bottomInset: bottomInset, hideTrack: hideTrack)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.attach(from: nsView, topInset: topInset, bottomInset: bottomInset, hideTrack: hideTrack)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        private weak var scrollView: NSScrollView?

        func attach(from view: NSView, topInset: CGFloat, bottomInset: CGFloat, hideTrack: Bool) {
            let found = findScrollView(from: view)
            guard let found else { return }

            if scrollView !== found {
                scrollView = found
            }

            found.scrollerInsets = NSEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)

            if hideTrack, !(found.verticalScroller is TracklessScroller) {
                let trackless = TracklessScroller()
                trackless.controlSize = found.verticalScroller?.controlSize ?? .regular
                found.verticalScroller = trackless
            }
        }

        private func findScrollView(from view: NSView) -> NSScrollView? {
            var current: NSView? = view
            while let superview = current?.superview {
                current = superview
            }

            guard let root = current else { return nil }
            return findScrollView(in: root)
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }

            for subview in view.subviews {
                if let found = findScrollView(in: subview) {
                    return found
                }
            }

            return nil
        }
    }
}

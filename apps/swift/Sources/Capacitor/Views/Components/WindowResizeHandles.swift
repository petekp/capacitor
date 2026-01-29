// WindowResizeHandles.swift
//
// Adds invisible resize handles around window edges for easier grabbing.
// macOS floating windows without title bars have very thin resize areas.
// This component adds larger hit zones (default 8pt) that feel natural.
//
// Usage: Apply as an overlay on ContentView or any root view:
//   .overlay(WindowResizeHandles())

import SwiftUI
import AppKit

struct WindowResizeHandles: NSViewRepresentable {
    /// Width of the resize handle zones in points
    let handleWidth: CGFloat

    init(handleWidth: CGFloat = 8) {
        self.handleWidth = handleWidth
    }

    func makeNSView(context: Context) -> ResizeHandleContainerView {
        let view = ResizeHandleContainerView(handleWidth: handleWidth)
        return view
    }

    func updateNSView(_ nsView: ResizeHandleContainerView, context: Context) {
        nsView.handleWidth = handleWidth
    }
}

class ResizeHandleContainerView: NSView {
    var handleWidth: CGFloat

    init(handleWidth: CGFloat) {
        self.handleWidth = handleWidth
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Check if the point is within any edge zone
        let bounds = self.bounds

        // Define edge zones
        let leftZone = NSRect(x: 0, y: handleWidth, width: handleWidth, height: bounds.height - handleWidth * 2)
        let rightZone = NSRect(x: bounds.width - handleWidth, y: handleWidth, width: handleWidth, height: bounds.height - handleWidth * 2)
        let topZone = NSRect(x: handleWidth, y: bounds.height - handleWidth, width: bounds.width - handleWidth * 2, height: handleWidth)
        let bottomZone = NSRect(x: handleWidth, y: 0, width: bounds.width - handleWidth * 2, height: handleWidth)

        // Define corner zones (slightly larger for easier grabbing)
        let cornerSize = handleWidth * 1.5
        let topLeftCorner = NSRect(x: 0, y: bounds.height - cornerSize, width: cornerSize, height: cornerSize)
        let topRightCorner = NSRect(x: bounds.width - cornerSize, y: bounds.height - cornerSize, width: cornerSize, height: cornerSize)
        let bottomLeftCorner = NSRect(x: 0, y: 0, width: cornerSize, height: cornerSize)
        let bottomRightCorner = NSRect(x: bounds.width - cornerSize, y: 0, width: cornerSize, height: cornerSize)

        // Check corners first (they take priority)
        if topLeftCorner.contains(point) || topRightCorner.contains(point) ||
           bottomLeftCorner.contains(point) || bottomRightCorner.contains(point) ||
           leftZone.contains(point) || rightZone.contains(point) ||
           topZone.contains(point) || bottomZone.contains(point) {
            return self
        }

        // Pass through to underlying views
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window = self.window else {
            super.mouseDown(with: event)
            return
        }

        let locationInView = convert(event.locationInWindow, from: nil)
        let bounds = self.bounds

        // Determine resize direction based on click position
        let cornerSize = handleWidth * 1.5

        let isLeft = locationInView.x < handleWidth
        let isRight = locationInView.x > bounds.width - handleWidth
        let isTop = locationInView.y > bounds.height - handleWidth
        let isBottom = locationInView.y < handleWidth

        let isCornerLeft = locationInView.x < cornerSize
        let isCornerRight = locationInView.x > bounds.width - cornerSize
        let isCornerTop = locationInView.y > bounds.height - cornerSize
        let isCornerBottom = locationInView.y < cornerSize

        // Map to NSWindow resize edges
        // Note: In AppKit coordinates, y increases upward
        var edges: NSRectEdge? = nil

        // Corners (diagonal resize)
        if isCornerTop && isCornerLeft {
            performResize(window: window, event: event, edges: [.minX, .maxY])
            return
        } else if isCornerTop && isCornerRight {
            performResize(window: window, event: event, edges: [.maxX, .maxY])
            return
        } else if isCornerBottom && isCornerLeft {
            performResize(window: window, event: event, edges: [.minX, .minY])
            return
        } else if isCornerBottom && isCornerRight {
            performResize(window: window, event: event, edges: [.maxX, .minY])
            return
        }

        // Edges (single-axis resize)
        if isLeft {
            edges = .minX
        } else if isRight {
            edges = .maxX
        } else if isTop {
            edges = .maxY
        } else if isBottom {
            edges = .minY
        }

        if let edge = edges {
            performResize(window: window, event: event, edges: [edge])
        } else {
            super.mouseDown(with: event)
        }
    }

    private func performResize(window: NSWindow, event: NSEvent, edges: Set<NSRectEdge>) {
        // Use the system resize behavior
        let initialFrame = window.frame
        let initialMouseLocation = NSEvent.mouseLocation

        // Track mouse movement
        var isDragging = true

        while isDragging {
            guard let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) else {
                continue
            }

            switch nextEvent.type {
            case .leftMouseUp:
                isDragging = false
            case .leftMouseDragged:
                let currentMouseLocation = NSEvent.mouseLocation
                let deltaX = currentMouseLocation.x - initialMouseLocation.x
                let deltaY = currentMouseLocation.y - initialMouseLocation.y

                var newFrame = initialFrame

                // Apply deltas based on which edges are being resized
                if edges.contains(.minX) {
                    newFrame.origin.x = initialFrame.origin.x + deltaX
                    newFrame.size.width = initialFrame.size.width - deltaX
                }
                if edges.contains(.maxX) {
                    newFrame.size.width = initialFrame.size.width + deltaX
                }
                if edges.contains(.minY) {
                    newFrame.origin.y = initialFrame.origin.y + deltaY
                    newFrame.size.height = initialFrame.size.height - deltaY
                }
                if edges.contains(.maxY) {
                    newFrame.size.height = initialFrame.size.height + deltaY
                }

                // Respect minimum size
                if let minSize = window.contentMinSize as NSSize? {
                    if newFrame.size.width < minSize.width {
                        if edges.contains(.minX) {
                            newFrame.origin.x = initialFrame.maxX - minSize.width
                        }
                        newFrame.size.width = minSize.width
                    }
                    if newFrame.size.height < minSize.height {
                        if edges.contains(.minY) {
                            newFrame.origin.y = initialFrame.maxY - minSize.height
                        }
                        newFrame.size.height = minSize.height
                    }
                }

                // Respect maximum size
                if let maxSize = window.contentMaxSize as NSSize?, maxSize.width > 0, maxSize.height > 0 {
                    if newFrame.size.width > maxSize.width {
                        newFrame.size.width = maxSize.width
                    }
                    if newFrame.size.height > maxSize.height {
                        newFrame.size.height = maxSize.height
                    }
                }

                window.setFrame(newFrame, display: true)
            default:
                break
            }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        let bounds = self.bounds
        let cornerSize = handleWidth * 1.5

        // Edge zones with appropriate cursors
        let leftZone = NSRect(x: 0, y: cornerSize, width: handleWidth, height: bounds.height - cornerSize * 2)
        let rightZone = NSRect(x: bounds.width - handleWidth, y: cornerSize, width: handleWidth, height: bounds.height - cornerSize * 2)
        let topZone = NSRect(x: cornerSize, y: bounds.height - handleWidth, width: bounds.width - cornerSize * 2, height: handleWidth)
        let bottomZone = NSRect(x: cornerSize, y: 0, width: bounds.width - cornerSize * 2, height: handleWidth)

        // Corner zones
        let topLeftCorner = NSRect(x: 0, y: bounds.height - cornerSize, width: cornerSize, height: cornerSize)
        let topRightCorner = NSRect(x: bounds.width - cornerSize, y: bounds.height - cornerSize, width: cornerSize, height: cornerSize)
        let bottomLeftCorner = NSRect(x: 0, y: 0, width: cornerSize, height: cornerSize)
        let bottomRightCorner = NSRect(x: bounds.width - cornerSize, y: 0, width: cornerSize, height: cornerSize)

        // Add cursor rects
        addCursorRect(leftZone, cursor: .resizeLeftRight)
        addCursorRect(rightZone, cursor: .resizeLeftRight)
        addCursorRect(topZone, cursor: .resizeUpDown)
        addCursorRect(bottomZone, cursor: .resizeUpDown)

        // Diagonal cursors for corners
        // Note: macOS doesn't have built-in diagonal resize cursors, so we use a custom approach
        // For now, use the closest match
        addCursorRect(topLeftCorner, cursor: .crosshair)
        addCursorRect(topRightCorner, cursor: .crosshair)
        addCursorRect(bottomLeftCorner, cursor: .crosshair)
        addCursorRect(bottomRightCorner, cursor: .crosshair)
    }
}

// Set already has contains(), no extension needed

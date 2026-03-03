import AppKit

// MARK: - Window Anchoring Controller

@Observable
@MainActor
final class WindowAnchoringController {
    // MARK: - Public State

    private(set) var state: AnchoringState = .idle
    private(set) var activeSnapCandidate: SnapCandidate?

    // MARK: - Configuration

    static let snapThreshold: CGFloat = 150
    private static let titleBarHeight: CGFloat = 28
    private static let motionDecayThreshold = 30

    // MARK: - Dependencies

    private let boundsProvider: WindowBoundsProviding
    private weak var hudWindow: NSWindow?

    // MARK: - Timer

    @ObservationIgnored
    private var timer: DispatchSourceTimer?

    // MARK: - Event Monitors

    @ObservationIgnored
    private var mouseDownMonitor: Any?
    @ObservationIgnored
    private var mouseDraggedMonitor: Any?
    @ObservationIgnored
    private var mouseUpMonitor: Any?

    // MARK: - Tracking State

    @ObservationIgnored
    private var lastTargetBounds: CGRect?
    @ObservationIgnored
    private var dragCursorOrigin: CGPoint?
    /// The frame we last set programmatically via setFrame. Used to detect user-initiated moves.
    @ObservationIgnored
    private var lastSetFrame: CGRect?
    /// Timestamp of last detach. Used to suppress snap-back for a cooldown period.
    @ObservationIgnored
    private var lastDetachTime: CFTimeInterval = 0
    /// Cooldown period (seconds) after detach during which snap evaluation is suppressed.
    private static let detachCooldown: CFTimeInterval = 3.0

    // MARK: - Screen Change Observer

    @ObservationIgnored
    private var screenChangeObserver: NSObjectProtocol?

    // MARK: - HUD Move Detection

    @ObservationIgnored
    private var hudMoveObserver: NSObjectProtocol?
    /// Debounce work item for evaluating snap after HUD stops moving.
    @ObservationIgnored
    private var snapDebounceWork: DispatchWorkItem?

    // MARK: - Init

    init(boundsProvider: WindowBoundsProviding? = nil) {
        self.boundsProvider = boundsProvider ?? WindowBoundsProvider()

        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenChange()
            }
        }
    }

    deinit {
        timer?.cancel()
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseDraggedMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = screenChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = hudMoveObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    func configure(hudWindow: NSWindow) {
        self.hudWindow = hudWindow
        installPersistentHUDObserver()
    }

    func anchorTo(
        _ target: TargetWindowIdentity,
        edge: AnchorEdge,
        gap: CGFloat = 8,
        offset: CGFloat = 0,
    ) {
        let descriptor = AnchorDescriptor(
            target: target,
            edge: edge,
            gap: gap,
            offset: offset,
        )
        state = .anchored(descriptor)
        activeSnapCandidate = nil
        lastTargetBounds = nil

        // Initial position sync
        syncPosition(for: descriptor)

        installEventMonitors(for: descriptor)
        startTimer(interval: 0.5) // 2Hz heartbeat
        DebugLog.write("[Anchoring] Anchored to \(target.ownerName) (wid=\(target.windowID)) edge=\(edge.rawValue)")
    }

    func detach() {
        let wasAnchored = state.isAnchored
        state = .idle
        activeSnapCandidate = nil
        lastTargetBounds = nil
        lastSetFrame = nil
        dragCursorOrigin = nil

        stopTimer()
        removeEventMonitors()

        if wasAnchored {
            lastDetachTime = CACurrentMediaTime()
            DebugLog.write("[Anchoring] Detached")
        }
    }

    // MARK: - HUD Drag Lifecycle

    /// Tracks whether this drag started from an anchored state, and the descriptor at that time.
    @ObservationIgnored
    private var dragStartDescriptor: AnchorDescriptor?

    func hudDragBegan() {
        if let descriptor = state.descriptor {
            // Was anchored — save descriptor so hudDragEnded knows to detach.
            // Stop timer/monitors so they don't fight the system drag.
            dragStartDescriptor = descriptor
            stopTimer()
            removeEventMonitors()
        } else {
            dragStartDescriptor = nil
        }
        state = .idle
        // The persistent HUD move observer handles snap evaluation
        // when the HUD actually stops moving (debounced).
    }

    func hudDragEnded(hudFrame _: CGRect) {
        if dragStartDescriptor != nil {
            // Was anchored — user dragged the HUD, so detach completely.
            // Snap evaluation happens via the persistent HUD move observer
            // when the HUD actually stops moving (debounced).
            dragStartDescriptor = nil
            DebugLog.write("[Anchoring] Detached via HUD drag")
            return
        }

        // Don't evaluate snaps here — performDrag returns immediately (0ms)
        // due to isMovableByWindowBackground, so hudFrame is the PRE-drag position.
        // The persistent HUD move observer handles post-drag snap evaluation.
    }

    private func commitSnap(candidate: SnapCandidate, hudFrame: CGRect) {
        let targets = boundsProvider.visibleTargetWindows()
        let targetBounds = targets.first { $0.0 == candidate.identity }?.1
        let offset = targetBounds.map {
            Self.computeUserOffset(hudFrame: hudFrame, targetBounds: $0, edge: candidate.edge)
        } ?? 0

        anchorTo(
            candidate.identity,
            edge: candidate.edge,
            gap: 8,
            offset: offset,
        )
    }

    /// Computes the offset that preserves the HUD's current position relative to the target.
    /// For leading/trailing: vertical offset from top-aligned default.
    /// For top/bottom: horizontal offset from left-aligned default.
    private static func computeUserOffset(
        hudFrame: CGRect,
        targetBounds: CGRect,
        edge: AnchorEdge,
    ) -> CGFloat {
        switch edge {
        case .leading, .trailing:
            // Default y = targetBounds.maxY - hudSize.height; offset shifts from there
            hudFrame.origin.y - (targetBounds.maxY - hudFrame.height)
        case .top, .bottom:
            // Default x = targetBounds.minX; offset shifts from there
            hudFrame.origin.x - targetBounds.minX
        }
    }

    // MARK: - Snap Evaluation

    /// Evaluates snap candidates using edge-to-edge proximity.
    /// For each target × edge, measures how close the HUD's relevant edge is
    /// to the target window's corresponding edge, plus vertical overlap.
    private func evaluateSnapCandidates(hudFrame: CGRect) {
        let targets = boundsProvider.visibleTargetWindows()
        var bestCandidate: SnapCandidate?

        for (identity, targetBounds) in targets {
            for edge in AnchorEdge.allCases {
                let distance = edgeProximity(
                    hudFrame: hudFrame,
                    targetBounds: targetBounds,
                    edge: edge,
                )

                guard distance < Self.snapThreshold else { continue }

                // Only snap the perpendicular axis; preserve user's position on the parallel axis
                let offset = Self.computeUserOffset(
                    hudFrame: hudFrame,
                    targetBounds: targetBounds,
                    edge: edge,
                )
                let descriptor = AnchorDescriptor(
                    target: identity,
                    edge: edge,
                    gap: 8,
                    offset: offset,
                )
                let candidateFrame = descriptor.computeHUDFrame(
                    targetBounds: targetBounds,
                    hudSize: hudFrame.size,
                )

                if bestCandidate == nil || distance < bestCandidate!.distance {
                    bestCandidate = SnapCandidate(
                        identity: identity,
                        edge: edge,
                        hudFrame: candidateFrame,
                        distance: distance,
                    )
                }
            }
        }

        activeSnapCandidate = bestCandidate
    }

    /// Measures edge-to-edge distance between the HUD and a target window for a given edge.
    /// Returns the perpendicular gap distance, penalized if there's no vertical/horizontal overlap.
    private func edgeProximity(
        hudFrame: CGRect,
        targetBounds: CGRect,
        edge: AnchorEdge,
    ) -> CGFloat {
        switch edge {
        case .trailing:
            // HUD sits to the right of target: measure HUD.minX vs target.maxX
            let gap = abs(hudFrame.minX - targetBounds.maxX)
            let overlapPenalty = verticalOverlapPenalty(hudFrame: hudFrame, targetBounds: targetBounds)
            return gap + overlapPenalty
        case .leading:
            // HUD sits to the left of target: measure HUD.maxX vs target.minX
            let gap = abs(hudFrame.maxX - targetBounds.minX)
            let overlapPenalty = verticalOverlapPenalty(hudFrame: hudFrame, targetBounds: targetBounds)
            return gap + overlapPenalty
        case .top:
            // HUD sits above target: measure HUD.minY vs target.maxY
            let gap = abs(hudFrame.minY - targetBounds.maxY)
            let overlapPenalty = horizontalOverlapPenalty(hudFrame: hudFrame, targetBounds: targetBounds)
            return gap + overlapPenalty
        case .bottom:
            // HUD sits below target: measure HUD.maxY vs target.minY
            let gap = abs(hudFrame.maxY - targetBounds.minY)
            let overlapPenalty = horizontalOverlapPenalty(hudFrame: hudFrame, targetBounds: targetBounds)
            return gap + overlapPenalty
        }
    }

    /// Returns 0 if frames overlap vertically (good alignment), or the gap distance if they don't.
    private func verticalOverlapPenalty(hudFrame: CGRect, targetBounds: CGRect) -> CGFloat {
        let overlapMin = max(hudFrame.minY, targetBounds.minY)
        let overlapMax = min(hudFrame.maxY, targetBounds.maxY)
        if overlapMin < overlapMax { return 0 } // Overlapping vertically
        return overlapMin - overlapMax // Gap between vertical extents
    }

    /// Returns 0 if frames overlap horizontally, or the gap distance if they don't.
    private func horizontalOverlapPenalty(hudFrame: CGRect, targetBounds: CGRect) -> CGFloat {
        let overlapMin = max(hudFrame.minX, targetBounds.minX)
        let overlapMax = min(hudFrame.maxX, targetBounds.maxX)
        if overlapMin < overlapMax { return 0 }
        return overlapMin - overlapMax
    }

    // MARK: - Position Sync

    private func syncPosition(for descriptor: AnchorDescriptor) {
        guard let hudWindow else { return }
        guard let targetBounds = boundsProvider.bounds(for: descriptor.target.windowID) else {
            // Target window gone
            DebugLog.write("[Anchoring] Target lost (wid=\(descriptor.target.windowID))")
            detach()
            return
        }

        let hudSize = hudWindow.frame.size
        var newFrame = descriptor.computeHUDFrame(
            targetBounds: targetBounds,
            hudSize: hudSize,
        )
        newFrame = clampToScreen(newFrame)

        hudWindow.setFrame(newFrame, display: false)
        lastSetFrame = newFrame
        lastTargetBounds = targetBounds
    }

    private func syncPositionWithCursorDelta(
        for descriptor: AnchorDescriptor,
        delta: CGSize,
    ) {
        guard let hudWindow,
              let lastBounds = lastTargetBounds
        else {
            return
        }

        // Predict target position by applying cursor delta to last known bounds
        let predictedBounds = CGRect(
            x: lastBounds.origin.x + delta.width,
            y: lastBounds.origin.y + delta.height,
            width: lastBounds.width,
            height: lastBounds.height,
        )

        let hudSize = hudWindow.frame.size
        var newFrame = descriptor.computeHUDFrame(
            targetBounds: predictedBounds,
            hudSize: hudSize,
        )
        newFrame = clampToScreen(newFrame)

        hudWindow.setFrame(newFrame, display: false)
    }

    // MARK: - Timer Management

    private func startTimer(interval: TimeInterval) {
        stopTimer()

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(
            deadline: .now() + interval,
            repeating: interval,
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.pollTick()
            }
        }
        source.resume()
        timer = source
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func pollTick() {
        switch state {
        case .idle:
            stopTimer()

        case let .anchored(descriptor):
            // 2Hz heartbeat: check for user-initiated HUD move, then sync.
            // If the HUD has drifted significantly from where we last placed it
            // (and the target hasn't moved), the user must have dragged the HUD.
            if let lastFrame = lastSetFrame,
               let lastTarget = lastTargetBounds,
               let currentTarget = boundsProvider.bounds(for: descriptor.target.windowID),
               lastTarget == currentTarget
            {
                let actualFrame = hudWindow?.frame ?? .zero
                let drift = max(
                    abs(actualFrame.origin.x - lastFrame.origin.x),
                    abs(actualFrame.origin.y - lastFrame.origin.y),
                )
                if drift > 30 {
                    DebugLog.write("[Anchoring] HUD moved by user (\(Int(drift))px) — detaching")
                    detach()
                    return
                }
            }
            syncPosition(for: descriptor)

        case let .trackingDrag(descriptor, delta):
            // ~120Hz: cursor-delta prediction + CG bounds correction
            syncPositionWithCursorDelta(for: descriptor, delta: delta)
            // Also do a real bounds check to correct drift.
            // When we get fresh real bounds, reset the cursor origin so the
            // delta is always relative to the last confirmed bounds position.
            if let realBounds = boundsProvider.bounds(for: descriptor.target.windowID) {
                lastTargetBounds = realBounds
                dragCursorOrigin = NSEvent.mouseLocation
                state = .trackingDrag(descriptor, cursorDelta: .zero)
                // Re-sync with real bounds to eliminate any prediction drift
                syncPosition(for: descriptor)
            } else {
                DebugLog.write("[Anchoring] Target lost during drag (wid=\(descriptor.target.windowID))")
                detach()
            }

        case let .trackingMotion(descriptor, ticks):
            guard let currentBounds = boundsProvider.bounds(for: descriptor.target.windowID) else {
                DebugLog.write("[Anchoring] Target lost during motion tracking (wid=\(descriptor.target.windowID))")
                detach()
                return
            }

            if currentBounds != lastTargetBounds {
                // Still moving — sync and reset counter
                syncPosition(for: descriptor)
                state = .trackingMotion(descriptor, ticksSinceLastMove: 0)
            } else {
                let newTicks = ticks + 1
                if newTicks >= Self.motionDecayThreshold {
                    // Motion stopped — return to anchored heartbeat
                    state = .anchored(descriptor)
                    startTimer(interval: 0.5) // Back to 2Hz
                    DebugLog.write("[Anchoring] Motion stopped, returning to anchored heartbeat")
                } else {
                    state = .trackingMotion(descriptor, ticksSinceLastMove: newTicks)
                    // Decay timer: start at ~60Hz, ramp down toward 10Hz
                    if newTicks == 15 {
                        startTimer(interval: 0.1) // Drop to ~10Hz
                    }
                }
            }
        }
    }

    // MARK: - Event Monitors

    private func installEventMonitors(for descriptor: AnchorDescriptor) {
        removeEventMonitors()

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalMouseDown(event, descriptor: descriptor)
            }
        }

        mouseDraggedMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleGlobalMouseDragged(event, descriptor: descriptor)
            }
        }

        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleGlobalMouseUp(descriptor: descriptor)
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseDraggedMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDraggedMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
    }

    private func handleGlobalMouseDown(_: NSEvent, descriptor: AnchorDescriptor) {
        // Check if click is in target window's title bar region
        guard let targetBounds = boundsProvider.bounds(for: descriptor.target.windowID) else {
            return
        }

        let clickLocation = NSEvent.mouseLocation
        let titleBarRect = CGRect(
            x: targetBounds.origin.x,
            y: targetBounds.maxY - Self.titleBarHeight,
            width: targetBounds.width,
            height: Self.titleBarHeight,
        )

        if titleBarRect.contains(clickLocation) {
            dragCursorOrigin = clickLocation
            state = .trackingDrag(descriptor, cursorDelta: .zero)
            startTimer(interval: 1.0 / 120.0) // ~120Hz
            DebugLog.write("[Anchoring] Title bar click detected, entering trackingDrag")
        }
    }

    private func handleGlobalMouseDragged(_: NSEvent, descriptor: AnchorDescriptor) {
        guard case .trackingDrag = state,
              let origin = dragCursorOrigin
        else {
            // Not in drag tracking — check if bounds changed (programmatic move)
            if case .anchored = state {
                checkForMotion(descriptor: descriptor)
            }
            return
        }

        let currentLocation = NSEvent.mouseLocation
        let delta = CGSize(
            width: currentLocation.x - origin.x,
            height: currentLocation.y - origin.y,
        )
        state = .trackingDrag(descriptor, cursorDelta: delta)
    }

    private func handleGlobalMouseUp(descriptor: AnchorDescriptor) {
        guard case .trackingDrag = state else { return }

        dragCursorOrigin = nil

        // Force a real CG bounds sync
        syncPosition(for: descriptor)
        state = .anchored(descriptor)
        startTimer(interval: 0.5) // Back to 2Hz heartbeat
        DebugLog.write("[Anchoring] Mouse up, returning to anchored")
    }

    private func checkForMotion(descriptor: AnchorDescriptor) {
        guard let currentBounds = boundsProvider.bounds(for: descriptor.target.windowID) else {
            return
        }

        if currentBounds != lastTargetBounds {
            state = .trackingMotion(descriptor, ticksSinceLastMove: 0)
            startTimer(interval: 1.0 / 60.0) // ~60Hz
            syncPosition(for: descriptor)
            DebugLog.write("[Anchoring] Programmatic motion detected, entering trackingMotion")
        }
    }

    // MARK: - Screen Change

    private func handleScreenChange() {
        guard let descriptor = state.descriptor else { return }
        syncPosition(for: descriptor)
    }

    // MARK: - Persistent HUD Move Observer

    /// Installed once when the HUD window is configured. Detects user-initiated
    /// moves by comparing the actual frame against `lastSetFrame` (our last
    /// programmatic position). When the HUD stops moving (200ms debounce),
    /// evaluates snap candidates at the final resting position.
    private func installPersistentHUDObserver() {
        removeHUDMoveObserver()
        guard let hudWindow else { return }

        hudMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: hudWindow,
            queue: .main,
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self,
                      let window = notification.object as? NSWindow
                else { return }
                self.handleHUDMoved(frame: window.frame)
            }
        }
    }

    private func handleHUDMoved(frame _: CGRect) {
        // When anchored/tracking, our own setFrame calls trigger this notification.
        // Detach-on-drag is handled by the header callbacks (hudDragBegan) and
        // the drift check in pollTick — not here.
        guard state == .idle else { return }

        // HUD moved while idle — user is dragging it freely.
        // Debounce: evaluate snap candidates 200ms after the last movement.
        snapDebounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            evaluateSnapAfterDrag()
        }
        snapDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    /// Called 200ms after the HUD stops moving. Evaluates snap candidates
    /// at the HUD's actual final position.
    private func evaluateSnapAfterDrag() {
        guard state == .idle,
              let hudWindow
        else { return }

        // Suppress snap-back if we recently detached
        let timeSinceDetach = CACurrentMediaTime() - lastDetachTime
        if timeSinceDetach < Self.detachCooldown {
            DebugLog.write("[Anchoring] Skipping post-drag snap — cooldown (\(String(format: "%.1f", timeSinceDetach))s)")
            return
        }

        let hudFrame = hudWindow.frame
        evaluateSnapCandidates(hudFrame: hudFrame)
        if let candidate = activeSnapCandidate {
            commitSnap(candidate: candidate, hudFrame: hudFrame)
            DebugLog.write("[Anchoring] Post-drag snap to \(candidate.identity.ownerName) edge=\(candidate.edge.rawValue)")
        }
    }

    private func removeHUDMoveObserver() {
        if let observer = hudMoveObserver {
            NotificationCenter.default.removeObserver(observer)
            hudMoveObserver = nil
        }
        snapDebounceWork?.cancel()
        snapDebounceWork = nil
    }

    // MARK: - Helpers

    private func clampToScreen(_ frame: CGRect) -> CGRect {
        guard let screen = screenContaining(frame) ?? NSScreen.main else {
            return frame
        }

        let visibleFrame = screen.visibleFrame
        var result = frame

        if result.minX < visibleFrame.minX {
            result.origin.x = visibleFrame.minX
        }
        if result.maxX > visibleFrame.maxX {
            result.origin.x = visibleFrame.maxX - result.width
        }
        if result.minY < visibleFrame.minY {
            result.origin.y = visibleFrame.minY
        }
        if result.maxY > visibleFrame.maxY {
            result.origin.y = visibleFrame.maxY - result.height
        }

        return result
    }

    private func screenContaining(_ frame: CGRect) -> NSScreen? {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return NSScreen.screens.first { $0.frame.contains(center) }
    }
}

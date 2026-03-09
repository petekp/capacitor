import AppKit
import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode
    @State private var isQuickFeedbackPresented = false

    private var isOnListView: Bool {
        appState.navigationState.destination == .projectList
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header content
            HStack {
                // Show BackButton only when not on list view
                // Use conditional to avoid dead zones from invisible views blocking window drag
                if !isOnListView {
                    BackButton(title: "Projects") {
                        appState.navigationState.showProjectList()
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }

                Spacer()

                HeaderFeedbackButton {
                    isQuickFeedbackPresented = true
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, floatingMode ? 9 : 6)
            .padding(.bottom, 6)
            .background {
                if floatingMode {
                    // Use NSViewRepresentable for drag + double-click handling.
                    // Keep background clear so it matches the panel and avoids seams.
                    HeaderDragArea(
                        onDoubleClick: {
                            WindowFrameStore.shared.cycleCompactState()
                        },
                        onDragBegan: appState.isWindowAnchoringEnabled ? { [weak appState] in
                            appState?.anchoringController.hudDragBegan()
                        } : nil,
                        onDragEnded: appState.isWindowAnchoringEnabled ? { [weak appState] frame in
                            appState?.anchoringController.hudDragEnded(hudFrame: frame)
                        } : nil,
                    )
                } else {
                    Color.hudBackground
                }
            }
        }
        .sheet(isPresented: $isQuickFeedbackPresented) {
            QuickFeedbackSheet { draft, preferences, formSessionID, openGitHubIssue in
                appState.quickFeedbackWorkflow.submit(
                    draft,
                    preferences: preferences,
                    formSessionID: formSessionID,
                    openGitHubIssue: openGitHubIssue,
                )
            }
        }
    }
}

private struct HeaderFeedbackButton: View {
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 11, weight: .semibold))
                Text("Feedback")
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.72))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.14 : 0.0)),
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(isHovered ? 0.24 : 0.0), lineWidth: 0.5),
            )
        }
        .buttonStyle(.plain)
        .help("Quick Feedback")
        .accessibilityLabel("Feedback")
        .accessibilityHint("Open quick feedback sheet")
        .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1.0)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.2, dampingFraction: 0.75)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Header Drag Area

/// NSViewRepresentable that handles both window dragging and double-click actions.
/// Unlike SwiftUI's onTapGesture(count: 2), this doesn't block mouseDown events
/// needed for window dragging via isMovableByWindowBackground.
struct HeaderDragArea: NSViewRepresentable {
    let onDoubleClick: () -> Void
    let onDragBegan: (() -> Void)?
    let onDragEnded: ((CGRect) -> Void)?

    init(
        onDoubleClick: @escaping () -> Void,
        onDragBegan: (() -> Void)? = nil,
        onDragEnded: ((CGRect) -> Void)? = nil,
    ) {
        self.onDoubleClick = onDoubleClick
        self.onDragBegan = onDragBegan
        self.onDragEnded = onDragEnded
    }

    func makeNSView(context _: Context) -> HeaderDragNSView {
        let view = HeaderDragNSView()
        view.onDoubleClick = onDoubleClick
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
        return view
    }

    func updateNSView(_ nsView: HeaderDragNSView, context _: Context) {
        nsView.onDoubleClick = onDoubleClick
        nsView.onDragBegan = onDragBegan
        nsView.onDragEnded = onDragEnded
    }
}

class HeaderDragNSView: NSView {
    var onDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((CGRect) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            // Double-click: cycle compact state
            onDoubleClick?()
        } else {
            // Notify anchoring controller before drag starts
            onDragBegan?()
            let startTime = CACurrentMediaTime()
            // Single click: initiate window drag (blocks until mouse-up)
            window?.performDrag(with: event)
            let elapsed = CACurrentMediaTime() - startTime
            DebugLog.write("[Anchoring] performDrag returned after \(Int(elapsed * 1000))ms")
            // Drag ended — notify with final frame
            if let frame = window?.frame {
                onDragEnded?(frame)
            }
        }
    }

    override var mouseDownCanMoveWindow: Bool {
        // Panel uses isMovableByWindowBackground for system-level drag.
        // performDrag(with:) returns immediately (0ms) regardless of this value.
        // Keep true so the system participates in window dragging.
        true
    }
}

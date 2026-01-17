import SwiftUI

// MARK: - Shared Status Indicator

/// Unified status indicator with consistent uppercase monospaced treatment
struct StatusIndicator: View {
    let state: SessionState

    @Environment(\.prefersReducedMotion) private var reduceMotion

    private var statusColor: Color {
        Color.statusColor(for: state)
    }

    private var statusText: String {
        switch state {
        case .ready: return "Ready"
        case .working: return "Working"
        case .waiting: return "Waiting"
        case .compacting: return "Compacting"
        case .idle: return "Idle"
        }
    }

    private var isActive: Bool {
        state != .idle
    }

    var body: some View {
        Text(statusText.uppercased())
            .font(.system(.callout, design: .monospaced).weight(.semibold))
            .tracking(0.5)
            .foregroundColor(isActive ? statusColor : statusColor.opacity(0.55))
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? AppMotion.reducedMotionFallback : .smooth(duration: 0.3), value: state)
            .accessibilityLabel("Status: \(statusText)")
            .accessibilityValue(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch state {
        case .ready: return "Ready for input"
        case .working: return "Currently working on a task"
        case .waiting: return "Waiting for user action"
        case .compacting: return "Compacting conversation history"
        case .idle: return "Session is idle"
        }
    }
}

// MARK: - Shared Context Menu

/// Builds the standard context menu for project cards
struct ProjectContextMenu: View {
    let project: Project
    let devServerPort: UInt16?
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void
    var onCaptureIdea: (() -> Void)?
    let onRemove: () -> Void

    var body: some View {
        if project.isMissing {
            missingProjectMenu
        } else {
            normalProjectMenu
        }
    }

    @ViewBuilder
    private var missingProjectMenu: some View {
        Button(action: onInfoTap) {
            Label("View Details", systemImage: "info.circle")
        }
        Divider()
        Button(role: .destructive, action: onRemove) {
            Label("Remove from HUD", systemImage: "trash")
        }
    }

    @ViewBuilder
    private var normalProjectMenu: some View {
        Button(action: onTap) {
            Label("Open in Terminal", systemImage: "terminal")
        }
        if devServerPort != nil {
            Button(action: onOpenBrowser) {
                Label("Open in Browser", systemImage: "globe")
            }
        }
        Button(action: onInfoTap) {
            Label("View Details", systemImage: "info.circle")
        }
        if let onCaptureIdea = onCaptureIdea {
            Button(action: onCaptureIdea) {
                Label("Capture Idea...", systemImage: "lightbulb")
            }
        }
        Divider()
        Button(action: onMoveToDormant) {
            Label("Move to Paused", systemImage: "moon.zzz")
        }
        Button(role: .destructive, action: onRemove) {
            Label("Remove from HUD", systemImage: "trash")
        }
    }
}

// MARK: - Shared Card Background

/// Parameterized card background supporting both floating and solid modes
struct ProjectCardBackground: View {
    let isHovered: Bool
    var cornerRadius: CGFloat = 12

    @Environment(\.floatingMode) private var floatingMode

    #if DEBUG
    var config: GlassConfig?
    #endif

    var body: some View {
        if floatingMode {
            floatingBackground
        } else {
            solidBackground
        }
    }

    private var floatingBackground: some View {
        #if DEBUG
        if let config = config {
            DarkFrostedCard(isHovered: isHovered, config: config)
        } else {
            DarkFrostedCard(isHovered: isHovered)
        }
        #else
        DarkFrostedCard(isHovered: isHovered)
        #endif
    }

    private var solidBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(Color.hudCard)

            VStack(spacing: 0) {
                LinearGradient(
                    colors: [.white.opacity(isHovered ? 0.08 : 0.04), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 1)
                Spacer()
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))

            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(isHovered ? 0.18 : 0.1),
                            .white.opacity(isHovered ? 0.08 : 0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.5
                )
        }
    }
}

// MARK: - Shared Badges

/// Stale session badge
struct StaleBadge: View {
    var style: BadgeStyle = .normal

    enum BadgeStyle {
        case normal
        case compact
    }

    var body: some View {
        Text("stale")
            .font(style == .compact ? AppTypography.label : AppTypography.captionSmall.weight(.medium))
            .foregroundColor(.white.opacity(style == .compact ? 0.4 : 0.5))
            .padding(.horizontal, style == .compact ? 6 : 5)
            .padding(.vertical, 2)
            .background(Color.white.opacity(style == .compact ? 0.06 : 0.08))
            .clipShape(Capsule())
            .accessibilityLabel("Stale session")
            .accessibilityHint("This project has been ready for more than 24 hours without activity")
    }
}

/// Blocker indicator badge
struct BlockerBadge: View {
    var style: BadgeStyle = .normal

    enum BadgeStyle {
        case normal
        case compact
    }

    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(style == .compact ? AppTypography.label : AppTypography.captionSmall)
            .foregroundColor(.orange)
    }
}

// MARK: - Ideas Badge (shared)

struct IdeasBadge: View {
    let count: Int
    let isCardHovered: Bool
    @Binding var showPopover: Bool

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        Button(action: { showPopover.toggle() }) {
            HStack(spacing: 3) {
                Image(systemName: "lightbulb.fill")
                    .font(AppTypography.captionSmall)
                Text("\(count)")
                    .font(AppTypography.captionSmall.weight(.medium))
            }
            .foregroundColor(.hudAccent.opacity(isHovered ? 1.0 : (isCardHovered ? 0.8 : 0.6)))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.hudAccent.opacity(isHovered ? 0.2 : (isCardHovered ? 0.12 : 0.08)))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.hudAccent.opacity(isHovered ? 0.3 : 0), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .help("\(count) idea\(count == 1 ? "" : "s") - Click to view")
        .accessibilityLabel("\(count) idea\(count == 1 ? "" : "s")")
        .accessibilityHint("Opens ideas panel")
    }
}

// MARK: - Ideas Popover Content

struct IdeasPopoverContent: View {
    let ideas: [Idea]
    let remainingCount: Int
    let generatingTitleIds: Set<String>
    var onAddIdea: (() -> Void)?
    var onShowMore: (() -> Void)?
    var onWorkOnIdea: ((Idea) -> Void)?
    var onDismissIdea: ((Idea) -> Void)?

    private var totalCount: Int {
        ideas.count + remainingCount
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if ideas.isEmpty {
                emptyState
            } else {
                ideasList
            }

            if remainingCount > 0 {
                showMoreButton
            }

            Divider()
            addIdeaButton
        }
        .frame(width: 280)
    }

    private var header: some View {
        HStack {
            Image(systemName: "lightbulb.fill")
                .font(AppTypography.label)
                .foregroundColor(.hudAccent.opacity(0.8))

            Text("Ideas")
                .font(AppTypography.labelMedium)
                .foregroundColor(.primary)

            Text("(\(totalCount))")
                .font(AppTypography.badge)
                .foregroundColor(.secondary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No ideas yet")
                .font(AppTypography.bodySecondary)
                .foregroundColor(.secondary)
            Text("Capture ideas as you work")
                .font(AppTypography.caption)
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var ideasList: some View {
        VStack(spacing: 0) {
            ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                IdeaRow(
                    idea: idea,
                    isGeneratingTitle: generatingTitleIds.contains(idea.id),
                    onWorkOn: onWorkOnIdea.map { callback in { callback(idea) } },
                    onDismiss: onDismissIdea.map { callback in { callback(idea) } }
                )

                if index < ideas.count - 1 {
                    Divider()
                        .padding(.leading, 12)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var showMoreButton: some View {
        Button(action: { onShowMore?() }) {
            HStack {
                Spacer()
                Text("+ \(remainingCount) more ideas")
                    .font(AppTypography.labelMedium)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private var addIdeaButton: some View {
        Button(action: { onAddIdea?() }) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(AppTypography.label.weight(.medium))
                Text("Add Idea")
                    .font(AppTypography.labelMedium)
            }
            .foregroundColor(.hudAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add new idea")
    }
}

// MARK: - Idea Row

struct IdeaRow: View {
    let idea: Idea
    let isGeneratingTitle: Bool
    var onWorkOn: (() -> Void)?
    var onDismiss: (() -> Void)?

    @State private var isHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Text(idea.title)
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(2)
                    .opacity(isGeneratingTitle ? 0 : 1)

                if isGeneratingTitle {
                    Text("Saving idea...")
                        .font(AppTypography.bodySecondary)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered && !isGeneratingTitle {
                hoverActions
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(idea.title)
    }

    @ViewBuilder
    private var hoverActions: some View {
        HStack(spacing: 4) {
            if let onWorkOn = onWorkOn {
                Button(action: onWorkOn) {
                    Text("Work On")
                        .font(AppTypography.captionSmall.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            if let onDismiss = onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "checkmark")
                        .font(AppTypography.captionSmall.weight(.bold))
                        .foregroundColor(.white)
                        .frame(width: 18, height: 18)
                        .background(Color.green.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Mark as done")
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

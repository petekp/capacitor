import SwiftUI

struct IdeaDetailOverlay: View {
    let idea: Idea
    let orchestrationActivity: IdeaQueueActivity?
    let onDismiss: () -> Void
    let onReview: (() -> Void)?
    let onDelegate: (() -> Void)?
    let onRunMethod: (() -> Void)?
    let onRemove: () -> Void

    @State private var appeared = false

    private var canStartWork: Bool {
        orchestrationActivity == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with dismiss
            HStack {
                Text("Added \(formatRelativeDate(idea.added))")
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.35))

                Spacer()

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.5))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailDismissIdentifier)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 16)

            // Content
            VStack(alignment: .leading, spacing: 12) {
                Text(idea.title)
                    .font(AppTypography.sectionTitle.weight(.semibold))
                    .foregroundColor(.white)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)

                if !idea.description.isEmpty {
                    Text(idea.description)
                        .font(AppTypography.bodyMedium)
                        .foregroundColor(.white.opacity(0.7))
                        .lineSpacing(3)
                        .lineLimit(8)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 24)

            if let orchestrationPresentation {
                orchestrationStatusPanel(orchestrationPresentation)
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
            }

            Spacer(minLength: 20)

            // Actions
            HStack(spacing: 8) {
                if let onReview, let title = orchestrationPresentation?.reviewButtonTitle {
                    primaryActionButton(title: title, systemImage: "checkmark.circle.fill", action: onReview)
                        .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailReviewIdentifier)
                } else if canStartWork {
                    if let onRunMethod {
                        primaryActionButton(title: "Run Method", systemImage: "play.fill", action: onRunMethod)
                            .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailRunMethodIdentifier)
                    }

                    if let onDelegate {
                        secondaryActionButton(title: "Delegate", systemImage: "bolt.fill", action: onDelegate)
                            .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailDelegateIdentifier)
                    }
                }

                Spacer()

                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.red.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailRemoveIdentifier)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AccessibilityIdentifiers.ideaDetailIdentifier)
        .scaleEffect(appeared ? 1 : 0.96)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.9)) {
                appeared = true
            }
        }
    }

    private var orchestrationPresentation: IdeaDetailOrchestrationPresentation? {
        guard let orchestrationActivity else { return nil }

        switch orchestrationActivity {
        case .generatingTitle:
            return IdeaDetailOrchestrationPresentation(
                title: orchestrationActivity.label,
                detail: "Capacitor is turning the note into a queue title.",
                symbolName: "sparkles",
                tint: orchestrationActivity.tint,
                showsProgress: true,
                reviewButtonTitle: nil,
            )
        case .delegationWorking:
            return IdeaDetailOrchestrationPresentation(
                title: orchestrationActivity.label,
                detail: "The worker will pause here when a checkpoint is ready.",
                symbolName: "bolt.fill",
                tint: orchestrationActivity.tint,
                showsProgress: true,
                reviewButtonTitle: nil,
            )
        case .reviewReady:
            return IdeaDetailOrchestrationPresentation(
                title: orchestrationActivity.label,
                detail: "A worker checkpoint is waiting for your decision.",
                symbolName: "checkmark.circle.fill",
                tint: orchestrationActivity.tint,
                showsProgress: false,
                reviewButtonTitle: "Review Worker",
            )
        case let .methodRunning(phaseName):
            return IdeaDetailOrchestrationPresentation(
                title: orchestrationActivity.label,
                detail: phaseName == nil
                    ? "The method run is moving through its workflow."
                    : "The method run will pause when it needs input.",
                symbolName: "play.fill",
                tint: orchestrationActivity.tint,
                showsProgress: true,
                reviewButtonTitle: nil,
            )
        case .methodCheckpointReady:
            return IdeaDetailOrchestrationPresentation(
                title: orchestrationActivity.label,
                detail: "A method checkpoint is waiting for your decision.",
                symbolName: "checkmark.circle.fill",
                tint: orchestrationActivity.tint,
                showsProgress: false,
                reviewButtonTitle: "Review Checkpoint",
            )
        case .inProgress:
            return IdeaDetailOrchestrationPresentation(
                title: orchestrationActivity.label,
                detail: "This idea is already marked as in progress.",
                symbolName: "circle.fill",
                tint: orchestrationActivity.tint,
                showsProgress: false,
                reviewButtonTitle: nil,
            )
        }
    }

    private func orchestrationStatusPanel(_ presentation: IdeaDetailOrchestrationPresentation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(presentation.tint.opacity(0.16))
                    .frame(width: 30, height: 30)

                if presentation.showsProgress {
                    ProgressView()
                        .controlSize(.small)
                        .tint(presentation.tint)
                        .scaleEffect(0.72)
                } else {
                    Image(systemName: presentation.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(presentation.tint)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(1)

                Text(presentation.detail)
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.58))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(presentation.tint.opacity(0.18), lineWidth: 0.75),
        )
    }

    private func primaryActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(AppTypography.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(.black.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(AppTypography.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundColor(.white.opacity(0.8))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private static let mediumDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private func formatRelativeDate(_ dateString: String) -> String {
        guard let date = parseISO8601Date(dateString) else {
            return dateString
        }
        return relativeString(from: date)
    }

    private func relativeString(from date: Date) -> String {
        let components = Calendar.current.dateComponents([.day, .hour, .minute], from: date, to: Date())

        if let days = components.day, days > 7 {
            return Self.mediumDateFormatter.string(from: date)
        } else if let days = components.day, days > 0 {
            return "\(days)d ago"
        } else if let hours = components.hour, hours > 0 {
            return "\(hours)h ago"
        } else if let minutes = components.minute, minutes > 0 {
            return "\(minutes)m ago"
        } else {
            return "just now"
        }
    }
}

struct IdeaDetailModalOverlay: View {
    let idea: Idea?
    let anchorFrame: CGRect?
    let orchestrationActivity: IdeaQueueActivity?
    let onDismiss: () -> Void
    let onReview: ((Idea) -> Void)?
    let onDelegate: ((Idea) -> Void)?
    let onRunMethod: ((Idea) -> Void)?
    let onRemove: (Idea) -> Void

    @State private var escapeMonitor: Any?

    var body: some View {
        ZStack {
            if let idea {
                scrimBackground
                    .onTapGesture { onDismiss() }

                IdeaDetailOverlay(
                    idea: idea,
                    orchestrationActivity: orchestrationActivity,
                    onDismiss: onDismiss,
                    onReview: onReview.map { handler in { handler(idea) } },
                    onDelegate: onDelegate.map { handler in { handler(idea) } },
                    onRunMethod: onRunMethod.map { handler in { handler(idea) } },
                    onRemove: { onRemove(idea) },
                )
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.92), value: idea != nil)
        .onChange(of: idea != nil) { _, isPresented in
            if isPresented {
                installEscapeMonitor()
            } else {
                removeEscapeMonitor()
            }
        }
        .onDisappear {
            removeEscapeMonitor()
        }
    }

    private var scrimBackground: some View {
        ZStack {
            Color.black.opacity(0.5)

            VibrancyView(
                material: .fullScreenUI,
                blendingMode: .behindWindow,
                isEmphasized: false,
                forceDarkAppearance: true,
            )
            .opacity(0.4)
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }

    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                onDismiss()
                return nil
            }
            return event
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}

private struct IdeaDetailOrchestrationPresentation {
    let title: String
    let detail: String
    let symbolName: String
    let tint: Color
    let showsProgress: Bool
    let reviewButtonTitle: String?
}

import SwiftUI

struct SetupStatusCard: View {
    let diagnostic: HookDiagnosticReport
    let onFix: () -> Void
    let onRefresh: () -> Void

    @State private var isExpanded = false
    @State private var isFixing = false
    @State private var isHovered = false
    @State private var fixButtonHovered = false
    @Environment(\.prefersReducedMotion) private var reduceMotion

    var body: some View {
        if diagnostic.isHealthy {
            EmptyView()
        } else {
            cardContent
        }
    }

    private var cardContent: some View {
        VStack(spacing: 0) {
            collapsedHeader
            if isExpanded {
                expandedContent
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(cardBackgroundColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(cardBackgroundColor.opacity(0.2), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityDescription)
    }

    private var collapsedHeader: some View {
        Button(action: {
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .spring(response: 0.3, dampingFraction: 0.8)) {
                isExpanded.toggle()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: headerIcon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(cardBackgroundColor)

                Text(headerMessage)
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.8))

                Spacer()

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.4))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
                .background(cardBackgroundColor.opacity(0.2))

            statusChecklist
                .padding(.horizontal, 12)

            if let issue = diagnostic.primaryIssue, isPolicyBlocked(issue) {
                policyBlockedMessage
                    .padding(.horizontal, 12)
            } else if diagnostic.canAutoFix {
                fixButton
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 12)
    }

    private var statusChecklist: some View {
        VStack(alignment: .leading, spacing: 6) {
            checklistItem(
                label: "Hook binary installed",
                isOk: diagnostic.binaryOk
            )
            checklistItem(
                label: "Settings configured",
                isOk: diagnostic.configOk
            )
            checklistItem(
                label: firingLabel,
                isOk: diagnostic.firingOk,
                isPending: diagnostic.isFirstRun && diagnostic.binaryOk && diagnostic.configOk
            )
        }
    }

    private var firingLabel: String {
        if diagnostic.isFirstRun && diagnostic.binaryOk && diagnostic.configOk {
            return "Waiting for first Claude session"
        }
        return "Hooks responding"
    }

    private func checklistItem(label: String, isOk: Bool, isPending: Bool = false) -> some View {
        HStack(spacing: 6) {
            if isPending {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                Image(systemName: isOk ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isOk ? .green.opacity(0.8) : .red.opacity(0.8))
            }
            Text(label)
                .font(AppTypography.captionSmall)
                .foregroundColor(.white.opacity(isPending ? 0.5 : 0.7))
        }
    }

    private var policyBlockedMessage: some View {
        VStack(alignment: .leading, spacing: 4) {
            if case .policyBlocked(let reason) = diagnostic.primaryIssue {
                Text(reason)
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.6))
                Text("Remove this setting to enable session tracking.")
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var fixButton: some View {
        HStack {
            Spacer()
            Button(action: {
                guard !isFixing else { return }
                isFixing = true
                onFix()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isFixing = false
                    onRefresh()
                }
            }) {
                HStack(spacing: 6) {
                    if isFixing {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "wrench.and.screwdriver")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text("Fix All")
                        .font(AppTypography.caption.weight(.semibold))
                }
                .foregroundColor(.white.opacity(fixButtonHovered ? 1.0 : 0.9))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.hudAccent.opacity(fixButtonHovered ? 0.9 : 0.7))
                )
            }
            .buttonStyle(.plain)
            .disabled(isFixing)
            .onHover { hovering in
                withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                    fixButtonHovered = hovering
                }
            }
        }
    }

    private var headerIcon: String {
        if diagnostic.isFirstRun {
            return "hand.wave.fill"
        }
        if let issue = diagnostic.primaryIssue, isPolicyBlocked(issue) {
            return "lock.fill"
        }
        return "exclamationmark.triangle.fill"
    }

    private var headerMessage: String {
        if diagnostic.isFirstRun {
            return "Let's get you set up"
        }
        if let issue = diagnostic.primaryIssue, isPolicyBlocked(issue) {
            return "Hooks disabled by policy"
        }
        return "Session tracking unavailable"
    }

    private var cardBackgroundColor: Color {
        if diagnostic.isFirstRun {
            return .blue
        }
        if let issue = diagnostic.primaryIssue, isPolicyBlocked(issue) {
            return .purple
        }
        return .orange
    }

    private var accessibilityDescription: String {
        if diagnostic.isFirstRun {
            return "Setup required. \(headerMessage)"
        }
        return "Warning. \(headerMessage)"
    }

    private func isPolicyBlocked(_ issue: HookIssue) -> Bool {
        if case .policyBlocked = issue {
            return true
        }
        return false
    }
}

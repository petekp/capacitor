import SwiftUI

struct SetupStatusCard: View {
    let diagnostic: HookDiagnosticReport
    let onFix: () -> Void
    let onRefresh: () -> Void
    let onTest: () -> HookTestResult

    @State private var isExpanded = false
    @State private var isFixing = false
    @State private var isHovered = false
    @State private var fixButtonHovered = false
    @State private var isTesting = false
    @State private var testResult: HookTestResult?
    @State private var testButtonHovered = false
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
                .fill(cardBackgroundColor.opacity(0.1)),
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(cardBackgroundColor.opacity(0.2), lineWidth: 0.5),
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

            diagnosticDetails
                .padding(.horizontal, 12)

            testHookButton
                .padding(.horizontal, 12)

            if let message = diagnostic.setupCardGuidanceMessage {
                guidanceMessage(message)
                    .padding(.horizontal, 12)
            }

            if diagnostic.canAutoFix {
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
                isOk: diagnostic.binaryOk,
            )
            checklistItem(
                label: "Settings configured",
                isOk: diagnostic.configOk,
            )
            checklistItem(
                label: firingLabel,
                isOk: diagnostic.firingOk,
                isPending: diagnostic.isFirstRun && diagnostic.binaryOk && diagnostic.configOk,
            )
        }
    }

    private var firingLabel: String {
        if diagnostic.isFirstRun, diagnostic.binaryOk, diagnostic.configOk {
            return "Waiting for first Claude session"
        }
        return "Hooks responding"
    }

    private var diagnosticDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .background(Color.white.opacity(0.1))
                .padding(.vertical, 4)

            detailRow(label: "Binary", value: formatPath(diagnostic.symlinkPath))

            if let target = diagnostic.symlinkTarget {
                detailRow(label: "→ Target", value: formatPath(target))
            }

            detailRow(label: "Last seen", value: formatHeartbeatAge(diagnostic.lastHeartbeatAgeSecs))
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(AppTypography.captionSmall)
                .foregroundColor(.white.opacity(0.4))
                .frame(width: 55, alignment: .leading)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func formatPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func formatHeartbeatAge(_ ageSecs: UInt64?) -> String {
        guard let age = ageSecs else {
            return "Never"
        }
        if age < 60 {
            return "\(age)s ago"
        } else if age < 3600 {
            return "\(age / 60)m ago"
        } else {
            return "\(age / 3600)h ago"
        }
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

    private func guidanceMessage(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(AppTypography.captionSmall)
                .foregroundColor(.white.opacity(0.58))
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
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        runHookTest()
                    }
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
                        .fill(Color.hudAccent.opacity(fixButtonHovered ? 0.9 : 0.7)),
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

    private var testHookButton: some View {
        HStack(spacing: 8) {
            Button(action: runHookTest) {
                HStack(spacing: 6) {
                    if isTesting {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else if let result = testResult {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(result.success ? .green : .orange)
                    } else {
                        Image(systemName: "play.circle")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(testButtonLabel)
                        .font(AppTypography.captionSmall.weight(.medium))
                }
                .foregroundColor(.white.opacity(testButtonHovered ? 0.9 : 0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color.white.opacity(testButtonHovered ? 0.12 : 0.08)),
                )
            }
            .buttonStyle(.plain)
            .disabled(isTesting)
            .onHover { hovering in
                withAnimation(reduceMotion ? AppMotion.reducedMotionFallback : .easeOut(duration: 0.15)) {
                    testButtonHovered = hovering
                }
            }

            if let result = testResult {
                Text(result.message)
                    .font(AppTypography.captionSmall)
                    .foregroundColor(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()
        }
    }

    private var testButtonLabel: String {
        if isTesting {
            return "Testing..."
        }
        if let result = testResult {
            return result.success ? "✓ Working" : "✗ Issue"
        }
        return "Test Hooks"
    }

    private func runHookTest() {
        guard !isTesting else { return }
        isTesting = true
        testResult = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result = onTest()
            DispatchQueue.main.async {
                testResult = result
                isTesting = false

                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    if testResult?.success == result.success {
                        testResult = nil
                    }
                }
            }
        }
    }

    private var headerIcon: String {
        if diagnostic.isFirstRun {
            return "hand.wave.fill"
        }
        if diagnostic.setupCardIsPolicyBlocked {
            return "lock.fill"
        }
        switch diagnostic.primaryIssue {
        case .binaryMissing:
            return "wrench.and.screwdriver.fill"
        case .binaryBroken, .symlinkBroken:
            return "exclamationmark.octagon.fill"
        case .configMissing:
            return "slider.horizontal.3"
        case .notFiring:
            return "bolt.slash.fill"
        case .policyBlocked:
            return "lock.fill"
        case nil:
            return "exclamationmark.triangle.fill"
        }
    }

    private var headerMessage: String {
        diagnostic.setupCardHeaderMessage
    }

    private var cardBackgroundColor: Color {
        if diagnostic.isFirstRun {
            return .blue
        }
        if diagnostic.setupCardIsPolicyBlocked {
            return .purple
        }
        switch diagnostic.primaryIssue {
        case .binaryBroken, .symlinkBroken:
            return .red
        case .configMissing:
            return .yellow
        default:
            return .orange
        }
    }

    private var accessibilityDescription: String {
        if diagnostic.isFirstRun {
            return "Setup required. \(headerMessage)"
        }
        return "Warning. \(headerMessage)"
    }
}

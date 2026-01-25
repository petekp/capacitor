import SwiftUI

struct SetupStepRow: View {
    let step: SetupStep
    let isCurrentStep: Bool
    var actionLabel: String = "Install"
    var linkURL: URL?
    var linkLabel: String = "Download"
    var onAction: (() -> Void)?
    var onRetry: (() -> Void)?

    private var hasActions: Bool {
        switch step.status {
        case .actionNeeded: onAction != nil
        case .error: linkURL != nil || onRetry != nil || onAction != nil
        default: false
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: hasActions ? 10 : 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title)
                        .font(.headline)
                        .foregroundStyle(titleColor)

                    Text(step.statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }

                actionButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.2), value: step.status)
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        switch step.status {
        case .pending:
            Image(systemName: "circle")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)

        case .checking:
            ProgressView()
                .scaleEffect(0.8)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(.green)

        case .actionNeeded:
            Image(systemName: "circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.accentColor)

        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundStyle(.yellow)
        }
    }

    // MARK: - Action Button

    @ViewBuilder
    private var actionButton: some View {
        switch step.status {
        case .actionNeeded:
            if let onAction {
                Button(actionLabel, action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        case .error:
            HStack(spacing: 6) {
                if let linkURL {
                    Link(linkLabel, destination: linkURL)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if let onAction, linkURL == nil {
                    Button(actionLabel, action: onAction)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Styling

    private var titleColor: Color {
        switch step.status {
        case .pending:
            .secondary
        case .error:
            .primary
        default:
            .primary
        }
    }

    private var detailColor: Color {
        switch step.status {
        case .error:
            .yellow
        default:
            .secondary
        }
    }

    private var rowBackground: Color {
        switch step.status {
        case .actionNeeded where isCurrentStep:
            Color.accentColor.opacity(0.1)
        case .error:
            Color.yellow.opacity(0.1)
        default:
            Color.primary.opacity(0.05)
        }
    }
}

#Preview("All States") {
    VStack(spacing: 12) {
        SetupStepRow(
            step: SetupStep(
                id: "claude",
                title: "Claude Code",
                description: "Capacitor reads your Claude sessions to show live project status",
                status: .completed(detail: "Installed"),
            ),
            isCurrentStep: false,
        )

        SetupStepRow(
            step: SetupStep(
                id: "hooks",
                title: "Session tracking",
                description: "See which projects are active and what Claude is working on",
                status: .checking,
            ),
            isCurrentStep: true,
        )

        SetupStepRow(
            step: SetupStep(
                id: "hooks",
                title: "Session tracking",
                description: "See which projects are active and what Claude is working on",
                status: .actionNeeded(message: "Tap Install to connect"),
            ),
            isCurrentStep: true,
            onAction: { print("Install tapped") },
        )

        SetupStepRow(
            step: SetupStep(
                id: "claude",
                title: "Claude Code",
                description: "Capacitor reads your Claude sessions to show live project status",
                status: .error(message: "Not found — download from claude.ai/download"),
            ),
            isCurrentStep: true,
            linkURL: URL(string: "https://claude.ai/download"),
            onRetry: { print("Retry tapped") },
        )

        SetupStepRow(
            step: SetupStep(
                id: "shell",
                title: "Terminal tracking",
                description: "Add hook to ~/.zshrc to auto-detect which project each terminal is in",
                status: .pending,
                isOptional: true,
            ),
            isCurrentStep: false,
        )
    }
    .padding()
    .frame(width: 400)
    .preferredColorScheme(.dark)
}

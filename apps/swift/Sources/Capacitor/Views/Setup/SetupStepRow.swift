import SwiftUI

struct SetupStepRow: View {
    let step: SetupStep
    let isCurrentStep: Bool
    var onAction: (() -> Void)?
    var onRetry: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.headline)
                    .foregroundStyle(titleColor)

                Text(step.statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(detailColor)
            }

            Spacer()

            actionButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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
                Button("Install", action: onAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        case .error:
            if let onRetry {
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Styling

    private var titleColor: Color {
        switch step.status {
        case .pending:
            return .secondary
        case .error:
            return .primary
        default:
            return .primary
        }
    }

    private var detailColor: Color {
        switch step.status {
        case .error:
            return .yellow
        default:
            return .secondary
        }
    }

    private var rowBackground: Color {
        switch step.status {
        case .actionNeeded where isCurrentStep:
            return Color.accentColor.opacity(0.1)
        case .error:
            return Color.yellow.opacity(0.1)
        default:
            return Color.primary.opacity(0.05)
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        SetupStepRow(
            step: SetupStep(
                id: "storage",
                title: "Storage directory",
                description: "~/.capacitor/",
                status: .completed(detail: "~/.capacitor/ ready")
            ),
            isCurrentStep: false
        )

        SetupStepRow(
            step: SetupStep(
                id: "tmux",
                title: "tmux",
                description: "Required for project tracking",
                status: .checking
            ),
            isCurrentStep: true
        )

        SetupStepRow(
            step: SetupStep(
                id: "hooks",
                title: "Session hooks",
                description: "Required for live state tracking",
                status: .actionNeeded(message: "Not installed yet")
            ),
            isCurrentStep: true,
            onAction: { print("Install tapped") }
        )

        SetupStepRow(
            step: SetupStep(
                id: "tmux",
                title: "tmux",
                description: "Required for project tracking",
                status: .error(message: "Not found. Install with: brew install tmux")
            ),
            isCurrentStep: false,
            onRetry: { print("Retry tapped") }
        )

        SetupStepRow(
            step: SetupStep(
                id: "project",
                title: "Add your first project",
                description: "Waiting for hooks...",
                status: .pending
            ),
            isCurrentStep: false
        )
    }
    .padding()
    .frame(width: 400)
    .preferredColorScheme(.dark)
}

import SwiftUI

struct EndOfDayClosureSection: View {
    let content: EndOfDayClosureContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: content.safeToStop ? "moon.stars.fill" : "exclamationmark.shield.fill")
                    .font(AppTypography.label)
                    .foregroundColor(content.safeToStop ? .hudAccent.opacity(0.82) : .orange.opacity(0.9))

                Text(content.title)
                    .font(AppTypography.labelMedium)
                    .foregroundColor(.white.opacity(0.58))

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.lines) { line in
                    EndOfDayClosureLineView(line: line)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.028))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 1),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityIdentifiers.endOfDayClosureIdentifier)
    }

    private var accessibilityLabel: String {
        ([content.title] + content.lines.map(\.text)).joined(separator: ", ")
    }
}

private struct EndOfDayClosureLineView: View {
    let line: EndOfDayClosureContent.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName)
                .font(AppTypography.captionSmall.weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 12)

            Text(line.text)
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.76))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch line.kind {
        case .openLoops:
            "circle.grid.cross"
        case .today:
            "calendar"
        case .decision:
            "exclamationmark.circle.fill"
        case .exception:
            "exclamationmark.triangle.fill"
        case .running:
            "checkmark.circle"
        case .completed:
            "checkmark.circle.fill"
        case .safeToStop:
            "power.circle.fill"
        }
    }

    private var tint: Color {
        switch line.kind {
        case .openLoops:
            .white.opacity(0.5)
        case .today:
            .hudAccent.opacity(0.78)
        case .decision:
            .orange.opacity(0.9)
        case .exception:
            .red.opacity(0.82)
        case .running:
            .hudAccent.opacity(0.75)
        case .completed:
            .green.opacity(0.75)
        case .safeToStop:
            .hudAccent.opacity(0.78)
        }
    }
}

#Preview {
    EndOfDayClosureSection(content: EndOfDayClosureContent.make(from: OperatorAttentionSummary(
        needsYou: [
            OperatorAttentionItem(
                id: "checkpoint",
                kind: .checkpoint,
                projectPath: "/tmp/project",
                title: "Evidence packet ready",
                reason: "Needs direction",
                ageLabel: nil,
                recommendedAction: "Review brief",
                target: .project(path: "/tmp/project"),
            ),
        ],
        runningNormally: [
            OperatorAttentionItem(
                id: "running",
                kind: .runningRun,
                projectPath: "/tmp/running",
                title: "Running",
                reason: "Working",
                ageLabel: nil,
                recommendedAction: nil,
                target: .project(path: "/tmp/running"),
            ),
        ],
        recentlyChanged: [],
        dormant: [],
        exceptions: [],
    )))
    .frame(width: 320)
    .padding()
    .background(Color.hudBackground)
}

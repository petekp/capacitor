import SwiftUI

struct ProjectCaseFileSection: View {
    let projection: ProjectCaseFileProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionLabel(title: "CASE FILE")

            VStack(alignment: .leading, spacing: 14) {
                currentStateView

                Divider()
                    .background(Color.white.opacity(0.08))

                caseFileGroup(
                    title: "Since Last Looked",
                    icon: "clock.arrow.circlepath",
                    lines: [projection.sinceLastLooked.summary],
                )

                if !projection.recentDecisions.isEmpty {
                    recentDecisionsView
                }

                caseFileGroup(
                    title: "Open Risks",
                    icon: "exclamationmark.triangle",
                    lines: projection.openRisks,
                )
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.07), lineWidth: 0.5),
                    ),
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ProjectCaseFileAccessibility.sectionLabel(for: projection))
    }

    private var currentStateView: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: projection.currentState.kind.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(projection.currentState.kind.tint.opacity(0.85))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(projection.currentState.title)
                        .font(AppTypography.body.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))

                    Text(projection.methodName)
                        .font(AppTypography.captionSmall.weight(.medium))
                        .foregroundColor(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Text(projection.currentState.detail)
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var recentDecisionsView: some View {
        VStack(alignment: .leading, spacing: 8) {
            caseFileHeader(title: "Recent Decisions", icon: "checklist.checked")

            VStack(alignment: .leading, spacing: 7) {
                ForEach(projection.recentDecisions) { decision in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(decision.label)
                                .font(AppTypography.captionSmall.weight(.bold))
                                .foregroundColor(.white.opacity(0.62))

                            Text(decision.title)
                                .font(AppTypography.caption)
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        }

                        if let note = decision.note {
                            Text(note)
                                .font(AppTypography.caption)
                                .foregroundColor(.white.opacity(0.48))
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func caseFileGroup(
        title: String,
        icon: String,
        lines: [String],
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            caseFileHeader(title: title, icon: icon)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(alignment: .top, spacing: 7) {
                        Circle()
                            .fill(Color.white.opacity(0.32))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)

                        Text(line)
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func caseFileHeader(title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.white.opacity(0.36))
                .frame(width: 12)

            Text(title.uppercased())
                .font(AppTypography.captionSmall.weight(.bold))
                .foregroundColor(.white.opacity(0.4))
        }
    }
}

enum ProjectCaseFileAccessibility {
    static func sectionLabel(for projection: ProjectCaseFileProjection) -> String {
        var parts = [
            "Case file",
            projection.projectName,
            projection.currentState.title,
            projection.currentState.detail,
            projection.sinceLastLooked.summary,
        ]

        if !projection.recentDecisions.isEmpty {
            parts.append("\(projection.recentDecisions.count) recent \(projection.recentDecisions.count == 1 ? "decision" : "decisions")")
        }

        parts.append("open risks: \(projection.openRisks.joined(separator: "; "))")
        return parts.joined(separator: ", ")
    }
}

private extension ProjectCaseFileProjection.CurrentStateKind {
    var symbolName: String {
        switch self {
        case .needsDecision:
            "hand.raised.circle.fill"
        case .running:
            "play.circle.fill"
        case .completed:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.circle.fill"
        case .recorded:
            "doc.text.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsDecision:
            .orange
        case .running:
            .statusWorking
        case .completed:
            .statusReady
        case .failed:
            .red
        case .recorded:
            .hudAccent
        }
    }
}

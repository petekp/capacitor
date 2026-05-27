import SwiftUI

struct ProjectCompletionBriefSection: View {
    let projection: ProjectCompletionBriefProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionLabel(title: "COMPLETION BRIEF")

            VStack(alignment: .leading, spacing: 14) {
                header

                Divider()
                    .background(Color.white.opacity(0.08))

                summaryGrid

                briefGroup(
                    title: "Evidence",
                    icon: "checkmark.seal",
                    lines: projection.evidence,
                )

                briefGroup(
                    title: "Residual Risk",
                    icon: "exclamationmark.triangle",
                    lines: projection.residualRisks,
                )
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.statusReady.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.statusReady.opacity(0.16), lineWidth: 0.5),
                    ),
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(ProjectCompletionBriefAccessibility.sectionLabel(for: projection))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color.statusReady.opacity(0.9))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(projection.headline)
                        .font(AppTypography.body.weight(.semibold))
                        .foregroundColor(.white.opacity(0.92))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(projection.methodName)
                        .font(AppTypography.captionSmall.weight(.medium))
                        .foregroundColor(.white.opacity(0.48))
                        .lineLimit(1)
                }

                Text(projection.outcome)
                    .font(AppTypography.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var summaryGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            valueRow(label: "Ready for", value: projection.readyFor)
            valueRow(label: "Confidence", value: projection.confidence)
        }
    }

    private func valueRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(AppTypography.captionSmall.weight(.bold))
                .foregroundColor(.white.opacity(0.38))
                .frame(width: 78, alignment: .leading)

            Text(value)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func briefGroup(
        title: String,
        icon: String,
        lines: [String],
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.36))
                    .frame(width: 12)

                Text(title.uppercased())
                    .font(AppTypography.captionSmall.weight(.bold))
                    .foregroundColor(.white.opacity(0.4))
            }

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
}

enum ProjectCompletionBriefAccessibility {
    static func sectionLabel(for projection: ProjectCompletionBriefProjection) -> String {
        [
            "Completion brief",
            projection.projectName,
            projection.headline,
            projection.outcome,
            "ready for: \(projection.readyFor)",
            "confidence: \(projection.confidence)",
            "evidence: \(projection.evidence.joined(separator: "; "))",
            "residual risks: \(projection.residualRisks.joined(separator: "; "))",
        ].joined(separator: ", ")
    }
}

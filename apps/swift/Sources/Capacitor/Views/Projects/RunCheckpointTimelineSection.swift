import SwiftUI

struct RunCheckpointTimelineSection: View {
    let projection: RunCheckpointTimelineProjection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionLabel(
                title: "RUN CHECKPOINTS",
                count: projection.entries.count,
                countAccessibilityLabel: "\(projection.entries.count) checkpoints",
            )

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(projection.entries.enumerated()), id: \.element.id) { index, entry in
                    RunCheckpointTimelineRow(
                        entry: entry,
                        isLast: index == projection.entries.count - 1,
                    )
                }
            }
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.runCheckpointTimelineIdentifier)
    }
}

private struct RunCheckpointTimelineRow: View {
    let entry: RunCheckpointTimelineProjection.Entry
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            timelineRail

            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.title)
                        .font(AppTypography.body.weight(.medium))
                        .foregroundColor(.white.opacity(0.86))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    decisionPill
                }

                HStack(spacing: 6) {
                    Text(entry.phaseName)
                        .font(AppTypography.caption.weight(.medium))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)

                    Text("Round \(entry.phaseRoundNumber)")
                        .font(AppTypography.monoCaption)
                        .foregroundColor(.white.opacity(0.44))

                    Text(entry.kindLabel)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.42))
                        .lineLimit(1)
                }

                if let summary = entry.summary, !summary.isEmpty {
                    Text(summary)
                        .font(AppTypography.caption)
                        .foregroundColor(.white.opacity(0.48))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let decisionNote = entry.decisionNote, !decisionNote.isEmpty {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "quote.opening")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundColor(entry.decisionState.tint.opacity(0.75))
                            .padding(.top, 2)

                        Text(decisionNote)
                            .font(AppTypography.caption)
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text(timestampText(for: entry))
                    .font(AppTypography.monoCaption)
                    .foregroundColor(.white.opacity(0.34))
            }
            .padding(.vertical, 10)
            .padding(.trailing, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.055), lineWidth: 0.5),
                ),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var timelineRail: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(entry.decisionState.tint.opacity(0.16))
                    .frame(width: 22, height: 22)

                Image(systemName: entry.decisionState.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(entry.decisionState.tint.opacity(0.9))
            }
            .padding(.top, 11)

            if !isLast {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.vertical, 4)
            }
        }
        .frame(width: 38)
    }

    private var decisionPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(entry.decisionState.tint.opacity(0.9))
                .frame(width: 5, height: 5)

            Text(entry.decisionState.label)
                .font(AppTypography.captionSmall.weight(.semibold))
                .foregroundColor(entry.decisionState.tint.opacity(0.92))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(entry.decisionState.tint.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(entry.decisionState.tint.opacity(0.2), lineWidth: 0.5),
                ),
        )
    }

    private var accessibilityLabel: String {
        var parts = [
            entry.title,
            entry.decisionState.label,
            entry.phaseName,
            "round \(entry.phaseRoundNumber)",
            entry.kindLabel,
            timestampText(for: entry),
        ]
        if let decisionNote = entry.decisionNote, !decisionNote.isEmpty {
            parts.append("note: \(decisionNote)")
        }
        return parts.joined(separator: ", ")
    }

    private func timestampText(for entry: RunCheckpointTimelineProjection.Entry) -> String {
        let timestamp = formattedTimestamp(entry.eventTimestamp)
        switch entry.timestampRole {
        case .created:
            return "Created \(timestamp)"
        case .decided:
            return "Decided \(timestamp)"
        case .recorded:
            return "Recorded \(timestamp)"
        }
    }

    private func formattedTimestamp(_ timestamp: String) -> String {
        guard let date = parseISO8601Date(timestamp) else {
            return timestamp
        }
        return runCheckpointTimelineTimestampFormatter.string(from: date)
    }
}

private extension RunCheckpointTimelineProjection.Entry.DecisionState {
    var label: String {
        switch self {
        case .awaitingReview:
            "Awaiting review"
        case .approved:
            "Approved"
        case .changesRequested:
            "Changes requested"
        case .decided:
            "Decided"
        case let .unknown(value):
            value
        }
    }

    var symbolName: String {
        switch self {
        case .awaitingReview:
            "pause.circle.fill"
        case .approved:
            "checkmark.circle.fill"
        case .changesRequested:
            "arrow.counterclockwise.circle.fill"
        case .decided:
            "checkmark.circle"
        case .unknown:
            "circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .awaitingReview:
            .orange.opacity(0.95)
        case .approved:
            .statusReady
        case .changesRequested:
            .statusWaiting
        case .decided:
            .hudAccent
        case .unknown:
            .white.opacity(0.55)
        }
    }
}

private let runCheckpointTimelineTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

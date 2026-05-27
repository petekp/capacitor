import SwiftUI

struct ReturnBriefContent: Equatable {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case sinceLastLooked
            case needsYou
            case recentlyChanged
            case runningNormally
            case exception
            case noAttention
        }

        let kind: Kind
        let text: String

        var id: Kind {
            kind
        }
    }

    let title: String
    let lastAppOpenedAt: Date?
    let lines: [Line]

    static func make(
        from summary: OperatorAttentionSummary,
        viewState: OperatorViewStateStore.Snapshot = .empty,
    ) -> ReturnBriefContent {
        var lines: [Line] = []

        if let sinceLastLooked = sinceLastLookedLine(
            from: summary,
            lastAppOpenedAt: viewState.lastAppOpenedAt,
        ) {
            lines.append(sinceLastLooked)
        }

        if !summary.needsYou.isEmpty {
            lines.append(Line(
                kind: .needsYou,
                text: "\(summary.needsYou.count) \(plural("decision", count: summary.needsYou.count)) \(summary.needsYou.count == 1 ? "needs" : "need") you",
            ))
        }

        if !summary.recentlyChanged.isEmpty {
            lines.append(Line(
                kind: .recentlyChanged,
                text: "\(summary.recentlyChanged.count) \(plural("worker", count: summary.recentlyChanged.count)) completed",
            ))
        }

        if !summary.runningNormally.isEmpty {
            lines.append(Line(
                kind: .runningNormally,
                text: "\(summary.runningNormally.count) \(plural("session", count: summary.runningNormally.count)) \(summary.runningNormally.count == 1 ? "is" : "are") healthy",
            ))
        }

        if !summary.exceptions.isEmpty {
            lines.append(Line(
                kind: .exception,
                text: exceptionText(for: summary.exceptions),
            ))
        }

        let hasAttention = !summary.needsYou.isEmpty
            || !summary.recentlyChanged.isEmpty
            || !summary.exceptions.isEmpty
        lines.append(Line(
            kind: .noAttention,
            text: hasAttention ? "Nothing else needs attention" : "Nothing needs attention",
        ))

        return ReturnBriefContent(
            title: "While you were away",
            lastAppOpenedAt: viewState.lastAppOpenedAt,
            lines: lines,
        )
    }

    private static func sinceLastLookedLine(
        from summary: OperatorAttentionSummary,
        lastAppOpenedAt: Date?,
    ) -> Line? {
        guard let lastAppOpenedAt else { return nil }

        let newDecisions = newItemCount(in: summary.needsYou, since: lastAppOpenedAt)
        let newCompletions = newItemCount(in: summary.recentlyChanged, since: lastAppOpenedAt)
        let newExceptions = newItemCount(in: summary.exceptions, since: lastAppOpenedAt)
        let healthyUpdates = newItemCount(in: summary.runningNormally, since: lastAppOpenedAt)

        let parts = [
            phrase(newDecisions, singular: "new decision"),
            phrase(newCompletions, singular: "new completion"),
            phrase(newExceptions, singular: "new exception"),
            phrase(healthyUpdates, singular: "healthy update"),
        ].compactMap(\.self)

        let text = parts.isEmpty
            ? "Nothing changed since you last looked"
            : "Since you last looked: \(parts.joined(separator: ", "))"

        return Line(kind: .sinceLastLooked, text: text)
    }

    private static func newItemCount(
        in items: [OperatorAttentionItem],
        since lastAppOpenedAt: Date,
    ) -> Int {
        items.count(where: { item in
            guard let lastChangedAt = item.lastChangedAt else { return false }
            return lastChangedAt > lastAppOpenedAt
        })
    }

    private static func phrase(_ count: Int, singular: String) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : "\(singular)s")"
    }

    private static func exceptionText(for items: [OperatorAttentionItem]) -> String {
        if items.allSatisfy({ $0.kind == .staleSession }) {
            return "\(items.count) \(plural("session", count: items.count)) \(items.count == 1 ? "looks" : "look") stale"
        }

        return "\(items.count) \(plural("item", count: items.count)) \(items.count == 1 ? "needs" : "need") inspection"
    }

    private static func plural(_ singular: String, count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
    }
}

struct ReturnBriefView: View {
    let content: ReturnBriefContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(AppTypography.label)
                    .foregroundColor(.hudAccent.opacity(0.85))

                Text(content.title)
                    .font(AppTypography.labelMedium)
                    .foregroundColor(.white.opacity(0.58))

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(content.lines) { line in
                    ReturnBriefLineView(line: line)
                }
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(AccessibilityIdentifiers.returnBriefIdentifier)
    }

    private var accessibilityLabel: String {
        ([content.title] + content.lines.map(\.text)).joined(separator: ", ")
    }
}

private struct ReturnBriefLineView: View {
    let line: ReturnBriefContent.Line

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbolName)
                .font(AppTypography.captionSmall.weight(.semibold))
                .foregroundColor(tint)
                .frame(width: 12)

            Text(line.text)
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(line.kind == .noAttention ? 0.55 : 0.78))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var symbolName: String {
        switch line.kind {
        case .sinceLastLooked:
            "clock.arrow.circlepath"
        case .needsYou:
            "exclamationmark.circle.fill"
        case .recentlyChanged:
            "checkmark.circle.fill"
        case .runningNormally:
            "checkmark.circle"
        case .exception:
            "exclamationmark.triangle.fill"
        case .noAttention:
            "circle"
        }
    }

    private var tint: Color {
        switch line.kind {
        case .sinceLastLooked:
            .hudAccent.opacity(0.78)
        case .needsYou:
            .orange.opacity(0.9)
        case .recentlyChanged:
            .green.opacity(0.75)
        case .runningNormally:
            .hudAccent.opacity(0.75)
        case .exception:
            .red.opacity(0.82)
        case .noAttention:
            .white.opacity(0.35)
        }
    }
}

#Preview {
    ReturnBriefView(content: ReturnBriefContent.make(from: OperatorAttentionSummary(
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

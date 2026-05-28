import Foundation

struct EndOfDayClosureContent: Equatable {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case openLoops
            case today
            case decision
            case exception
            case running
            case completed
            case safeToStop
        }

        let kind: Kind
        let text: String

        var id: Kind {
            kind
        }
    }

    let title: String
    let safeToStop: Bool
    let openLoopCount: Int
    let today: TodayCounters
    let lines: [Line]

    struct TodayCounters: Equatable {
        var completedRuns = 0
        var approvals = 0
        var requestedRevisions = 0

        var hasRecordedActivity: Bool {
            completedRuns > 0 || approvals > 0 || requestedRevisions > 0
        }
    }

    static func make(
        from summary: OperatorAttentionSummary,
        runs: [RuntimeRunState] = [],
        now: Date = Date(),
        calendar: Calendar = .current,
    ) -> EndOfDayClosureContent {
        let decisions = summary.needsYou.count
        let exceptions = summary.exceptions.count
        let running = summary.runningNormally.count
        let completed = summary.recentlyChanged.count
        let openLoops = decisions + exceptions + running + completed
        let safeToStop = decisions == 0 && exceptions == 0
        let today = todayCounters(from: runs, now: now, calendar: calendar)

        var lines: [Line] = [
            Line(kind: .openLoops, text: "Open loops: \(openLoops)"),
            Line(kind: .today, text: todayText(for: today)),
        ]

        if decisions > 0 {
            lines.append(Line(
                kind: .decision,
                text: "\(decisions) \(plural("decision", count: decisions)) \(decisions == 1 ? "needs" : "need") you",
            ))
        }

        if exceptions > 0 {
            lines.append(Line(
                kind: .exception,
                text: "\(exceptions) \(plural("item", count: exceptions)) \(exceptions == 1 ? "needs" : "need") inspection",
            ))
        }

        if completed > 0 {
            lines.append(Line(
                kind: .completed,
                text: "\(completed) completed \(plural("item", count: completed)) ready for review",
            ))
        }

        if running > 0 {
            lines.append(Line(
                kind: .running,
                text: "\(running) \(plural("session", count: running)) can keep running",
            ))
        }

        lines.append(Line(
            kind: .safeToStop,
            text: "Safe to stop: \(safeToStop ? "yes" : "no")",
        ))

        return EndOfDayClosureContent(
            title: "End of day",
            safeToStop: safeToStop,
            openLoopCount: openLoops,
            today: today,
            lines: lines,
        )
    }

    private static func todayCounters(
        from runs: [RuntimeRunState],
        now: Date,
        calendar: Calendar,
    ) -> TodayCounters {
        var counters = TodayCounters()

        for run in runs {
            if run.status == .completed,
               isToday(run.updatedAt, now: now, calendar: calendar)
            {
                counters.completedRuns += 1
            }

            for checkpoint in run.pastCheckpoints {
                guard let decision = checkpoint.decision,
                      let decidedAt = checkpoint.decidedAt,
                      isToday(decidedAt, now: now, calendar: calendar)
                else {
                    continue
                }

                switch decision.action {
                case "approve":
                    counters.approvals += 1
                case "request_changes", "rejected":
                    counters.requestedRevisions += 1
                default:
                    continue
                }
            }
        }

        return counters
    }

    private static func todayText(for counters: TodayCounters) -> String {
        guard counters.hasRecordedActivity else {
            return "Today: no completed runs or decisions recorded"
        }

        let parts = [
            phrase(counters.completedRuns, singular: "run completed", plural: "runs completed"),
            phrase(counters.approvals, singular: "checkpoint approved", plural: "checkpoints approved"),
            phrase(counters.requestedRevisions, singular: "revision requested", plural: "revisions requested"),
        ].compactMap(\.self)

        return "Today: \(parts.joined(separator: ", "))"
    }

    private static func isToday(
        _ timestamp: String,
        now: Date,
        calendar: Calendar,
    ) -> Bool {
        guard let date = parseISO8601Date(timestamp) else { return false }
        return calendar.isDate(date, inSameDayAs: now)
    }

    private static func phrase(
        _ count: Int,
        singular: String,
        plural: String,
    ) -> String? {
        guard count > 0 else { return nil }
        return "\(count) \(count == 1 ? singular : plural)"
    }

    private static func plural(_ singular: String, count: Int) -> String {
        count == 1 ? singular : "\(singular)s"
    }
}

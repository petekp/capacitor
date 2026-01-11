import SwiftUI

struct UsageInsightsSection: View {
    let projectPath: String?
    @StateObject private var insightsManager = UsageInsightsManager()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionLabel(title: "USAGE INSIGHTS")

            if insightsManager.isLoading {
                HStack {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Loading insights...")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
            } else if let insights = insightsManager.insights {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 16) {
                        InsightMetric(
                            value: "\(insights.sessionsThisWeek)",
                            label: "sessions this week",
                            icon: "bubble.left.and.bubble.right"
                        )

                        InsightMetric(
                            value: formatTokens(insights.tokensThisWeek),
                            label: "tokens this week",
                            icon: "text.alignleft"
                        )
                    }

                    HStack(spacing: 16) {
                        InsightMetric(
                            value: "$\(String(format: "%.2f", insights.estimatedCost))",
                            label: "est. total cost",
                            icon: "dollarsign.circle"
                        )

                        InsightMetric(
                            value: "\(insights.totalSessions)",
                            label: "total sessions",
                            icon: "chart.bar"
                        )
                    }

                    if !insightsManager.dailyUsage.isEmpty {
                        UsageSparkline(data: insightsManager.dailyUsage)
                            .frame(height: 40)
                            .padding(.top, 4)
                    }

                    if insights.averageSessionLength > 0 {
                        Text("Avg \(formatTokens(insights.averageSessionLength)) tokens/session")
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.4))
                    }

                    if !insights.coachingTips.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(insights.coachingTips) { tip in
                                CoachingTipRow(tip: tip)
                            }
                        }
                        .padding(.top, 4)
                    }
                }
            } else {
                Text("No usage data available")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .onAppear {
            insightsManager.loadInsights(for: projectPath)
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }
}

struct InsightMetric: View {
    let value: String
    let label: String
    let icon: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.4))

            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.85))

                Text(label)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.4))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct UsageSparkline: View {
    let data: [DailyUsage]

    private var maxTokens: Int {
        data.map { $0.tokens }.max() ?? 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Last 7 days")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.3))

            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(data) { day in
                        let height = maxTokens > 0 ? CGFloat(day.tokens) / CGFloat(maxTokens) : 0

                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(
                                    LinearGradient(
                                        colors: [.accentColor.opacity(0.7), .accentColor.opacity(0.4)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .frame(height: max(2, height * (geometry.size.height - 12)))

                            Text(dayLabel(day.date))
                                .font(.system(size: 6))
                                .foregroundColor(.white.opacity(0.3))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    private func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return String(formatter.string(from: date).prefix(1))
    }
}

struct CoachingTipRow: View {
    let tip: CoachingTip

    private var tipColor: Color {
        switch tip.type {
        case .positive:
            return .green
        case .suggestion:
            return .blue
        case .warning:
            return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: tip.icon)
                .font(.system(size: 10))
                .foregroundColor(tipColor.opacity(0.8))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(tip.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.8))

                Text(tip.message)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(tipColor.opacity(0.08))
        .cornerRadius(6)
    }
}

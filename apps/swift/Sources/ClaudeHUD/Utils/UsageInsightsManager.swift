import Foundation
import Combine

struct UsageInsights {
    let totalSessions: Int
    let totalInputTokens: Int
    let totalOutputTokens: Int
    let totalCacheReadTokens: Int
    let estimatedCost: Double
    let sessionsThisWeek: Int
    let tokensThisWeek: Int
    let mostActiveDay: String?
    let averageSessionLength: Int
    let coachingTips: [CoachingTip]
}

struct CoachingTip: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let message: String
    let type: TipType

    enum TipType {
        case positive
        case suggestion
        case warning
    }
}

struct DailyUsage: Identifiable {
    let id = UUID()
    let date: Date
    let sessions: Int
    let tokens: Int
}

class UsageInsightsManager: ObservableObject {
    @Published var insights: UsageInsights?
    @Published var dailyUsage: [DailyUsage] = []
    @Published var isLoading = false

    private let projectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")
    private let fileManager = FileManager.default

    private let inputTokenCostPer1M: Double = 3.0
    private let outputTokenCostPer1M: Double = 15.0
    private let cacheReadCostPer1M: Double = 0.30

    func loadInsights(for projectPath: String? = nil) {
        isLoading = true

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var totalSessions = 0
            var totalInputTokens = 0
            var totalOutputTokens = 0
            var totalCacheReadTokens = 0
            var sessionsThisWeek = 0
            var tokensThisWeek = 0
            var dailyStats: [String: (sessions: Int, tokens: Int)] = [:]

            let oneWeekAgo = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"

            do {
                let projectDirs = try self.fileManager.contentsOfDirectory(atPath: self.projectsDir)

                for projectDir in projectDirs {
                    if let projectPath = projectPath {
                        let encodedPath = projectPath.replacingOccurrences(of: "/", with: "-")
                        if !projectDir.contains(encodedPath) && encodedPath != projectDir {
                            continue
                        }
                    }

                    let projectSessionsPath = (self.projectsDir as NSString).appendingPathComponent(projectDir)
                    guard let sessions = try? self.fileManager.contentsOfDirectory(atPath: projectSessionsPath) else { continue }

                    for sessionFile in sessions where sessionFile.hasSuffix(".jsonl") {
                        let sessionPath = (projectSessionsPath as NSString).appendingPathComponent(sessionFile)
                        guard let attributes = try? self.fileManager.attributesOfItem(atPath: sessionPath),
                              let modDate = attributes[.modificationDate] as? Date else { continue }

                        totalSessions += 1

                        let dayKey = dateFormatter.string(from: modDate)
                        var dayStats = dailyStats[dayKey] ?? (sessions: 0, tokens: 0)
                        dayStats.sessions += 1

                        if let content = try? String(contentsOfFile: sessionPath, encoding: .utf8) {
                            let (input, output, cache) = self.parseTokens(from: content)
                            totalInputTokens += input
                            totalOutputTokens += output
                            totalCacheReadTokens += cache

                            let sessionTokens = input + output
                            dayStats.tokens += sessionTokens

                            if modDate >= oneWeekAgo {
                                sessionsThisWeek += 1
                                tokensThisWeek += sessionTokens
                            }
                        }

                        dailyStats[dayKey] = dayStats
                    }
                }
            } catch {
                print("Failed to load usage insights: \(error)")
            }

            let estimatedCost = (Double(totalInputTokens) / 1_000_000 * self.inputTokenCostPer1M) +
                               (Double(totalOutputTokens) / 1_000_000 * self.outputTokenCostPer1M) +
                               (Double(totalCacheReadTokens) / 1_000_000 * self.cacheReadCostPer1M)

            let mostActiveDay = dailyStats.max { $0.value.sessions < $1.value.sessions }?.key

            let avgSessionLength = totalSessions > 0 ? (totalInputTokens + totalOutputTokens) / totalSessions : 0

            let last7Days = (0..<7).compactMap { offset -> DailyUsage? in
                guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
                let key = dateFormatter.string(from: date)
                let stats = dailyStats[key] ?? (sessions: 0, tokens: 0)
                return DailyUsage(date: date, sessions: stats.sessions, tokens: stats.tokens)
            }.reversed()

            let tips = self.generateCoachingTips(
                totalSessions: totalSessions,
                sessionsThisWeek: sessionsThisWeek,
                totalInputTokens: totalInputTokens,
                totalOutputTokens: totalOutputTokens,
                totalCacheReadTokens: totalCacheReadTokens,
                averageSessionLength: avgSessionLength,
                estimatedCost: estimatedCost
            )

            DispatchQueue.main.async {
                self.insights = UsageInsights(
                    totalSessions: totalSessions,
                    totalInputTokens: totalInputTokens,
                    totalOutputTokens: totalOutputTokens,
                    totalCacheReadTokens: totalCacheReadTokens,
                    estimatedCost: estimatedCost,
                    sessionsThisWeek: sessionsThisWeek,
                    tokensThisWeek: tokensThisWeek,
                    mostActiveDay: mostActiveDay,
                    averageSessionLength: avgSessionLength,
                    coachingTips: tips
                )
                self.dailyUsage = Array(last7Days)
                self.isLoading = false
            }
        }
    }

    private func parseTokens(from content: String) -> (input: Int, output: Int, cache: Int) {
        var input = 0
        var output = 0
        var cache = 0

        let inputPattern = #"\"input_tokens\"\s*:\s*(\d+)"#
        let outputPattern = #"\"output_tokens\"\s*:\s*(\d+)"#
        let cachePattern = #"\"cache_read_input_tokens\"\s*:\s*(\d+)"#

        if let regex = try? NSRegularExpression(pattern: inputPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    input += Int(content[range]) ?? 0
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: outputPattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    output += Int(content[range]) ?? 0
                }
            }
        }

        if let regex = try? NSRegularExpression(pattern: cachePattern) {
            let matches = regex.matches(in: content, range: NSRange(content.startIndex..., in: content))
            for match in matches {
                if let range = Range(match.range(at: 1), in: content) {
                    cache += Int(content[range]) ?? 0
                }
            }
        }

        return (input, output, cache)
    }

    private func generateCoachingTips(
        totalSessions: Int,
        sessionsThisWeek: Int,
        totalInputTokens: Int,
        totalOutputTokens: Int,
        totalCacheReadTokens: Int,
        averageSessionLength: Int,
        estimatedCost: Double
    ) -> [CoachingTip] {
        var tips: [CoachingTip] = []

        let totalTokens = totalInputTokens + totalOutputTokens
        let cacheRatio = totalTokens > 0 ? Double(totalCacheReadTokens) / Double(totalTokens) : 0

        if cacheRatio > 0.3 {
            tips.append(CoachingTip(
                icon: "bolt.fill",
                title: "Great cache usage!",
                message: "You're leveraging prompt caching well (\(Int(cacheRatio * 100))% cache hits), saving on costs.",
                type: .positive
            ))
        } else if totalSessions > 10 && cacheRatio < 0.1 {
            tips.append(CoachingTip(
                icon: "lightbulb",
                title: "Enable prompt caching",
                message: "Consider longer sessions to benefit from Claude's prompt caching feature.",
                type: .suggestion
            ))
        }

        if averageSessionLength > 500_000 {
            tips.append(CoachingTip(
                icon: "arrow.down.right.circle",
                title: "Consider smaller sessions",
                message: "Very long sessions (\(averageSessionLength / 1000)K avg) may benefit from breaking into focused tasks.",
                type: .suggestion
            ))
        } else if averageSessionLength > 0 && averageSessionLength < 10_000 && totalSessions > 5 {
            tips.append(CoachingTip(
                icon: "checkmark.circle.fill",
                title: "Efficient sessions",
                message: "Your average session size (\(averageSessionLength / 1000)K tokens) shows focused, efficient usage.",
                type: .positive
            ))
        }

        if sessionsThisWeek >= 20 {
            tips.append(CoachingTip(
                icon: "flame.fill",
                title: "Power user!",
                message: "You're actively using Claude Code with \(sessionsThisWeek) sessions this week.",
                type: .positive
            ))
        } else if sessionsThisWeek == 0 && totalSessions > 0 {
            tips.append(CoachingTip(
                icon: "clock.arrow.circlepath",
                title: "Welcome back!",
                message: "No sessions this week. Pick up where you left off!",
                type: .suggestion
            ))
        }

        if estimatedCost > 100 {
            tips.append(CoachingTip(
                icon: "dollarsign.circle",
                title: "Cost awareness",
                message: "You've used an estimated $\(String(format: "%.0f", estimatedCost)) in API costs. Consider reviewing expensive sessions.",
                type: .warning
            ))
        }

        let outputRatio = totalTokens > 0 ? Double(totalOutputTokens) / Double(totalTokens) : 0
        if outputRatio > 0.8 && totalSessions > 5 {
            tips.append(CoachingTip(
                icon: "text.bubble",
                title: "High output ratio",
                message: "Claude is generating a lot of content (\(Int(outputRatio * 100))% output). Consider more focused prompts if responses are too long.",
                type: .suggestion
            ))
        }

        return tips
    }
}

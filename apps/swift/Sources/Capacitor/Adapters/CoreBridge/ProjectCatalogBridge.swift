import Foundation

enum ProjectCatalogBridge {
    static func projectCatalogEntries(from projects: [Project]) -> [ShellProjectCatalogEntry] {
        projects.map(projectCatalogEntry)
    }

    static func projectCatalogEntry(from project: Project) -> ShellProjectCatalogEntry {
        ShellProjectCatalogEntry(
            displayName: project.name,
            path: project.path,
            displayPath: project.displayPath,
            lastActiveAt: project.lastActive,
            claudeMdPath: project.claudeMdPath,
            claudeMdPreview: project.claudeMdPreview,
            hasLocalSettings: project.hasLocalSettings,
            taskCount: project.taskCount,
            stats: project.stats.map(projectStats),
            isMissing: project.isMissing,
        )
    }

    static func suggestedProjectCandidates(from projects: [SuggestedProject]) -> [ShellSuggestedProjectCandidate] {
        projects.map(suggestedProjectCandidate)
    }

    static func suggestedProjectCandidate(from project: SuggestedProject) -> ShellSuggestedProjectCandidate {
        ShellSuggestedProjectCandidate(
            displayName: project.name,
            path: project.path,
            displayPath: project.displayPath,
            taskCount: project.taskCount,
            hasClaudeMd: project.hasClaudeMd,
            hasProjectIndicators: project.hasProjectIndicators,
        )
    }

    private static func projectStats(from stats: ProjectStats) -> ShellProjectStats {
        ShellProjectStats(
            totalInputTokens: stats.totalInputTokens,
            totalOutputTokens: stats.totalOutputTokens,
            totalCacheReadTokens: stats.totalCacheReadTokens,
            totalCacheCreationTokens: stats.totalCacheCreationTokens,
            opusMessages: stats.opusMessages,
            sonnetMessages: stats.sonnetMessages,
            haikuMessages: stats.haikuMessages,
            sessionCount: stats.sessionCount,
            latestSummary: stats.latestSummary,
            firstActivity: stats.firstActivity,
            lastActivity: stats.lastActivity,
        )
    }
}

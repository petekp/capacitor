import Foundation

enum WorkBatchMetadataIgnoreInstaller {
    private static let marker = "# Capacitor Work Batch metadata"
    private static let ignorePattern = ".capacitor/"

    static func install(
        in worktreePath: String,
        fileManager: FileManager = .default,
    ) throws {
        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let gitURL = worktreeURL.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gitURL.path, isDirectory: &isDirectory) else {
            return
        }

        let gitDirectoryURL: URL
        if isDirectory.boolValue {
            gitDirectoryURL = gitURL
        } else {
            let contents = try String(contentsOf: gitURL, encoding: .utf8)
            guard let gitdirLine = contents
                .split(whereSeparator: \.isNewline)
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("gitdir:") })
            else {
                return
            }
            let rawPath = gitdirLine
                .dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawPath.isEmpty else { return }

            if rawPath.hasPrefix("/") {
                gitDirectoryURL = URL(fileURLWithPath: rawPath, isDirectory: true)
            } else {
                gitDirectoryURL = worktreeURL
                    .appendingPathComponent(rawPath, isDirectory: true)
                    .standardizedFileURL
            }
        }

        let excludeBaseURL = try commonGitDirectoryURL(
            for: gitDirectoryURL,
            fileManager: fileManager,
        )
        let excludeURL = excludeBaseURL
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude")
        try fileManager.createDirectory(
            at: excludeURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )

        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        let existingLines = Set(existing.split(whereSeparator: \.isNewline).map(String.init))
        guard !existingLines.contains(ignorePattern) else { return }

        var updated = existing
        if !updated.isEmpty, !updated.hasSuffix("\n") {
            updated.append("\n")
        }
        updated.append("\(Self.marker)\n\(Self.ignorePattern)\n")
        try updated.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    private static func commonGitDirectoryURL(
        for gitDirectoryURL: URL,
        fileManager: FileManager,
    ) throws -> URL {
        let commondirURL = gitDirectoryURL.appendingPathComponent("commondir")
        guard fileManager.fileExists(atPath: commondirURL.path) else {
            return gitDirectoryURL
        }

        let rawPath = try String(contentsOf: commondirURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            return gitDirectoryURL
        }

        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true)
                .standardizedFileURL
        }

        return gitDirectoryURL
            .appendingPathComponent(rawPath, isDirectory: true)
            .standardizedFileURL
    }
}

struct WorkBatchCompletionReport: Codable, Equatable {
    let taskID: String
    let status: String
    let summary: String
    let evidence: [String]
    let completedAt: Date?

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case status
        case summary
        case evidence
        case completedAt = "completed_at"
    }

    var isDone: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "done"
    }
}

struct WorkBatchLoadedCompletionReport: Equatable {
    let report: WorkBatchCompletionReport
    let url: URL
}

/// Thin wrapper over `JSONDirectoryStore`. Uncapped filename (fallback "task"), loads
/// every report (no record filter). `deleteReport` stays a completion-specific
/// capability — its canonical-remove + dedup-rescan is intentionally NOT pushed into
/// the generic store.
struct WorkBatchCompletionReportStore {
    static let relativeDirectory = ".capacitor/work-batch-completions"

    private let fileManager: FileManager
    private let store: JSONDirectoryStore<WorkBatchCompletionReport>

    init(
        worktreePath: String,
        fileManager: FileManager = .default,
    ) {
        self.fileManager = fileManager
        store = JSONDirectoryStore(
            worktreePath: worktreePath,
            fileManager: fileManager,
            relativeDirectory: Self.relativeDirectory,
            fileName: Self.reportFileName(taskID:),
            loadPredicate: { _ in true },
        )
    }

    func reportURL(taskID: String) -> URL {
        store.url(forID: taskID)
    }

    func loadReports() throws -> [WorkBatchLoadedCompletionReport] {
        try store.load().map { WorkBatchLoadedCompletionReport(report: $0.record, url: $0.url) }
    }

    func write(_ report: WorkBatchCompletionReport) throws -> URL {
        try store.write(report, id: report.taskID)
    }

    func deleteReport(taskID: String) throws {
        let url = reportURL(taskID: taskID)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }

        for loadedReport in try loadReports() where loadedReport.report.taskID == taskID {
            guard loadedReport.url != url,
                  fileManager.fileExists(atPath: loadedReport.url.path)
            else {
                continue
            }
            try fileManager.removeItem(at: loadedReport.url)
        }
    }

    static func reportFileName(taskID: String) -> String {
        "\(WorkBatchArtifactCodec.sanitizedIdentifier(taskID, fallback: "task", maxLength: nil)).json"
    }
}

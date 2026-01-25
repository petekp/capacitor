import Foundation

/*
 * TRANSPARENT-UI DEBUG TOOL
 *
 * Automatic diagnostic snapshots for stuck session detection.
 * Remove when no longer needed:
 * 1. Delete this file: apps/swift/Sources/Capacitor/Utilities/DiagnosticsSnapshotLogger.swift
 * 2. Remove calls in:
 *    - apps/swift/Sources/Capacitor/Models/AppState.swift
 *    - apps/swift/Sources/Capacitor/Models/SessionStateManager.swift
 *
 * Created for: hands-off debugging of "stuck working" session states.
 */
#if DEBUG
    @MainActor
    enum DiagnosticsSnapshotLogger {
        private struct SnapshotContext: Encodable {
            let activeProjectPath: String?
            let activeSource: String
        }

        private struct ProjectSnapshot: Encodable, Sendable {
            let projectPath: String
            let sessionId: String?
            let state: String
            let updatedAt: String?
            let stateChangedAt: String?
            let hasSession: Bool
            let thinking: Bool?
        }

        private struct StuckSession: Encodable, Sendable {
            let projectPath: String
            let sessionId: String?
            let state: String
            let updatedAt: String?
            let ageSeconds: Int
            let thinking: Bool?
        }

        private struct RuntimeSessionSnapshot: Encodable, Sendable {
            let sessionId: String
            let pid: UInt32
            let state: String
            let projectPath: String
            let updatedAt: String
            let stateChangedAt: String
            let lastEvent: String?
            let lastActivityAt: String?
            let toolsInFlight: Int?
            let readyReason: String?
            let isAlive: Bool?
        }

        private struct DiagnosticSnapshot: Encodable, Sendable {
            let timestamp: String
            let reason: String
            let context: SnapshotContext
            let stuckSessions: [StuckSession]
            let projectStates: [ProjectSnapshot]
            let runtimeSessions: [RuntimeSessionSnapshot]
        }

        private enum Constants {
            static let stuckThresholdSeconds: TimeInterval = 30
            static let throttleSeconds: TimeInterval = 5 * 60
        }

        private static let encoder: JSONEncoder = {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            return encoder
        }()

        private static let timestampFormatter: ISO8601DateFormatter = {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter
        }()

        private static let logURL: URL = {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return home.appendingPathComponent(".capacitor/runtime/diagnostic-snapshots.jsonl")
        }()

        private static var context = SnapshotContext(activeProjectPath: nil, activeSource: "none")
        private static var lastSnapshotByKey: [String: Date] = [:]

        static func updateContext(activeProjectPath: String?, activeSource: ActiveSource) {
            context = SnapshotContext(
                activeProjectPath: activeProjectPath,
                activeSource: String(describing: activeSource),
            )
        }

        static func maybeCaptureStuckSessions(sessionStates: [String: ProjectSessionState]) {
            let now = Date()
            let stuck = buildStuckSessions(from: sessionStates, now: now)
            guard !stuck.isEmpty else { return }

            let contextSnapshot = context
            let projectSnapshots = sessionStates.map { path, state in
                ProjectSnapshot(
                    projectPath: path,
                    sessionId: state.sessionId,
                    state: stateLabel(state.state),
                    updatedAt: state.updatedAt,
                    stateChangedAt: state.stateChangedAt,
                    hasSession: state.hasSession,
                    thinking: state.thinking,
                )
            }.sorted { $0.projectPath < $1.projectPath }

            _Concurrency.Task { @MainActor in
                let runtimeSessions = await (try? RuntimeClient.shared.fetchSessions()) ?? []
                let runtimeSnapshots = runtimeSessions.map { session in
                    RuntimeSessionSnapshot(
                        sessionId: session.sessionId,
                        pid: session.pid,
                        state: session.state,
                        projectPath: session.projectPath,
                        updatedAt: session.updatedAt,
                        stateChangedAt: session.stateChangedAt,
                        lastEvent: session.lastEvent,
                        lastActivityAt: session.lastActivityAt,
                        toolsInFlight: session.toolsInFlight,
                        readyReason: session.readyReason,
                        isAlive: session.isAlive,
                    )
                }

                let snapshot = DiagnosticSnapshot(
                    timestamp: timestampFormatter.string(from: Date()),
                    reason: "stuck_working",
                    context: contextSnapshot,
                    stuckSessions: stuck,
                    projectStates: projectSnapshots,
                    runtimeSessions: runtimeSnapshots,
                )

                writeSnapshot(snapshot)
            }
        }

        private static func buildStuckSessions(
            from sessionStates: [String: ProjectSessionState],
            now: Date,
        ) -> [StuckSession] {
            var stuck: [StuckSession] = []

            for (projectPath, state) in sessionStates {
                guard state.state == .working else { continue }
                if state.thinking == true { continue }
                guard let updatedAt = state.updatedAt,
                      let updatedDate = RuntimeDateParser.parse(updatedAt)
                else {
                    continue
                }
                let age = now.timeIntervalSince(updatedDate)
                guard age >= Constants.stuckThresholdSeconds else { continue }

                let key = state.sessionId ?? projectPath
                if let last = lastSnapshotByKey[key],
                   now.timeIntervalSince(last) < Constants.throttleSeconds
                {
                    continue
                }

                lastSnapshotByKey[key] = now
                stuck.append(
                    StuckSession(
                        projectPath: projectPath,
                        sessionId: state.sessionId,
                        state: stateLabel(state.state),
                        updatedAt: state.updatedAt,
                        ageSeconds: Int(age.rounded()),
                        thinking: state.thinking,
                    ),
                )
            }

            return stuck.sorted { $0.projectPath < $1.projectPath }
        }

        private static func stateLabel(_ state: SessionState) -> String {
            switch state {
            case .working: "working"
            case .ready: "ready"
            case .idle: "idle"
            case .compacting: "compacting"
            case .waiting: "waiting"
            }
        }

        private static func writeSnapshot(_ snapshot: DiagnosticSnapshot) {
            guard let data = try? encoder.encode(snapshot) else { return }
            let line = data + Data([0x0A])

            do {
                try append(line, to: logURL)
            } catch {
                DebugLog.write("DiagnosticsSnapshotLogger failed: \(error)")
            }
        }

        private static func append(_ data: Data, to url: URL) throws {
            let dir = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }
#endif

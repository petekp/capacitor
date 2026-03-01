import Foundation

/// Lightweight debug logger that appends to a file for deep diagnostics.
enum DebugLog {
    enum StartupEvent: Equatable {
        case claudeMissing
        case hooksBlockedByPolicy(reason: String)
        case hooksNeedAutoRepair(status: HookStatus)
        case hooksAutoRepairSucceeded
        case hooksAutoRepairFailedShowingWelcome
        case hooksAutoRepairFailed(error: String)
        case shellIntegrationInstalled(configFile: String)
        case shellIntegrationSkipped(reason: String)
        case autoSetupComplete
    }

    private enum Limits {
        static let maxBytes = 20 * 1024 * 1024
        static let retainBytes = 5 * 1024 * 1024
    }

    private static let logURL: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".capacitor/runtime/app-debug.log")
    }()

    private static let fallbackURL = URL(fileURLWithPath: "/tmp/capacitor-app-debug.log")
    private static let lock = NSLock()
    private static var testObserver: ((String) -> Void)?

    static func setTestObserver(_ observer: ((String) -> Void)?) {
        lock.lock()
        testObserver = observer
        lock.unlock()
    }

    static func write(
        _ message: String,
        to primaryURL: URL? = nil,
        fallbackURL overrideFallbackURL: URL? = fallbackURL,
        maxBytes: Int = Limits.maxBytes,
        retainBytes: Int = Limits.retainBytes,
    ) {
        let timestamp = currentISO8601Timestamp()
        let line = "[\(timestamp)] \(message)\n"
        let data = Data(line.utf8)

        let targetURL = primaryURL ?? logURL

        let observer: ((String) -> Void)? = {
            lock.lock()
            defer { lock.unlock() }
            return testObserver
        }()
        observer?(line)

        lock.lock()
        defer { lock.unlock() }

        do {
            try append(data, to: targetURL, maxBytes: maxBytes, retainBytes: retainBytes)
        } catch {
            guard let fallbackURL = overrideFallbackURL else { return }
            if fallbackURL != targetURL {
                do {
                    try append(data, to: fallbackURL, maxBytes: maxBytes, retainBytes: retainBytes)
                } catch {
                    // Intentionally ignore debug logging failures
                }
            }
        }
    }

    static func write(startup event: StartupEvent) {
        write(startupMessage(for: event))
    }

    private static func append(_ data: Data, to url: URL, maxBytes: Int, retainBytes: Int) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        try trimIfNeeded(url: url, maxBytes: maxBytes, retainBytes: retainBytes)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func trimIfNeeded(url: URL, maxBytes: Int, retainBytes: Int) throws {
        let size = try currentSize(of: url)
        guard size > Int64(maxBytes) else { return }

        let retained = max(0, min(retainBytes, maxBytes))
        guard retained > 0 else {
            try Data().write(to: url, options: .atomic)
            return
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let start = max(Int64(0), size - Int64(retained))
        try handle.seek(toOffset: UInt64(start))
        let tail = try handle.readToEnd() ?? Data()

        let timestamp = currentISO8601Timestamp()
        let header = Data("[\(timestamp)] [DebugLog] trimmed oversized log (size=\(size), retained=\(retained))\n".utf8)
        var compacted = Data()
        compacted.append(header)
        compacted.append(tail)
        try compacted.write(to: url, options: .atomic)
    }

    private static func currentSize(of url: URL) throws -> Int64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let raw = attrs[.size] as? NSNumber else { return 0 }
        return raw.int64Value
    }

    private static func startupMessage(for event: StartupEvent) -> String {
        let details = switch event {
        case .claudeMissing:
            "Claude CLI not found, showing WelcomeView"
        case let .hooksBlockedByPolicy(reason):
            if reason.isEmpty {
                "Hooks blocked by policy, showing WelcomeView"
            } else {
                "Hooks blocked by policy (\(reason)), showing WelcomeView"
            }
        case let .hooksNeedAutoRepair(status):
            "Hook status \(startupStatusLabel(for: status)) requires auto-repair"
        case .hooksAutoRepairSucceeded:
            "Hook auto-repair succeeded"
        case .hooksAutoRepairFailedShowingWelcome:
            "Hook auto-repair failed, showing WelcomeView"
        case let .hooksAutoRepairFailed(error):
            "Hook auto-repair failed: \(error)"
        case let .shellIntegrationInstalled(configFile):
            "Shell integration installed in \(configFile)"
        case let .shellIntegrationSkipped(reason):
            "Shell integration skipped: \(reason)"
        case .autoSetupComplete:
            "Auto-setup complete, skipping WelcomeView"
        }
        return "[Startup] \(details)"
    }

    private static func startupStatusLabel(for hookStatus: HookStatus) -> String {
        switch hookStatus {
        case .notInstalled:
            "notInstalled"
        case .installed:
            "installed"
        case .policyBlocked:
            "policyBlocked"
        case .binaryBroken:
            "binaryBroken"
        case .symlinkBroken:
            "symlinkBroken"
        }
    }
}

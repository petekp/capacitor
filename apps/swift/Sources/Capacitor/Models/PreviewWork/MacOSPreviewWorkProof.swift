import AppKit
import CryptoKit
import Foundation

enum MacOSPreviewWorkStatus: String, Codable, Equatable {
    case previewBuilding = "preview_building"
    case readyToInspect = "ready_to_inspect"
    case previewFailed = "preview_failed"
    case previewUnavailable = "preview_unavailable"
}

struct MacOSPreviewBundleIdentity: Codable, Equatable {
    let bundleID: String?
    let displayName: String?
}

struct MacOSPreviewLaunchedApplication: Equatable {
    let pid: Int32
    let bundleURL: URL?
    let bundleIdentifier: String?
    let localizedName: String?
    let launchTime: Date
    let executableURL: URL?

    init(
        pid: Int32,
        bundleURL: URL?,
        bundleIdentifier: String?,
        localizedName: String?,
        launchTime: Date,
        executableURL: URL? = nil,
    ) {
        self.pid = pid
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.localizedName = localizedName
        self.launchTime = launchTime
        self.executableURL = executableURL
    }
}

struct MacOSPreviewRunningApplication: Equatable {
    let pid: Int32
    let bundleURL: URL?
    let executableURL: URL?

    init(pid: Int32, bundleURL: URL?, executableURL: URL? = nil) {
        self.pid = pid
        self.bundleURL = bundleURL
        self.executableURL = executableURL
    }
}

struct MacOSPreviewWorkProof: Codable, Equatable {
    let status: MacOSPreviewWorkStatus
    let appPath: String?
    let bundleID: String?
    let displayName: String?
    let pid: Int32?
    let launchTime: Date?
    let worktreePath: String
    let gitHead: String?
    let dirtyState: String
    let sourceFingerprint: String?
    let buildCommand: String
    let buildLogPath: String
    let expectedBundleID: String
    let expectedDisplayName: String
    let failureReason: String?
    let recordedAt: Date

    var isReadyToInspect: Bool {
        status == .readyToInspect
    }
}

struct MacOSPreviewSourceSnapshot: Codable, Equatable {
    let gitHead: String?
    let dirtyState: String
    let fingerprint: String
}

struct MacOSPreviewWorkRequest: Equatable {
    let worktreeURL: URL
    let appURL: URL
    let expectedBundleID: String
    let expectedDisplayName: String
    let buildScriptURL: URL
    let buildLogURL: URL
    let proofURL: URL

    static func capacitorPreview(
        worktreeURL: URL = ReceiptFirstProofArtifacts.defaultCapacitorRoot(),
        proofDirectoryURL: URL? = nil,
        buildScriptURL: URL? = nil,
    ) -> MacOSPreviewWorkRequest {
        let standardizedWorktreeURL = worktreeURL.standardizedFileURL
        let defaultBuildScriptURL = ReceiptFirstProofArtifacts.defaultCapacitorRoot()
            .standardizedFileURL
            .appendingPathComponent("scripts/dev/build-preview-app.sh")
        let proofDirectoryURL = proofDirectoryURL ?? standardizedWorktreeURL
            .appendingPathComponent("docs/circuit/proofs/operator-product-loop/macos-preview-work", isDirectory: true)

        return MacOSPreviewWorkRequest(
            worktreeURL: standardizedWorktreeURL,
            appURL: standardizedWorktreeURL.appendingPathComponent("apps/swift/CapacitorPreview.app", isDirectory: true),
            expectedBundleID: "com.capacitor.app.preview",
            expectedDisplayName: "Capacitor Preview",
            buildScriptURL: (buildScriptURL ?? defaultBuildScriptURL).standardizedFileURL,
            buildLogURL: proofDirectoryURL.appendingPathComponent("latest-build.log"),
            proofURL: proofDirectoryURL.appendingPathComponent("latest-preview-proof.json"),
        )
    }
}

struct MacOSPreviewShellCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL
    let outputURL: URL?
}

struct MacOSPreviewShellCommandResult: Equatable {
    let exitCode: Int32
    let output: String?

    var succeeded: Bool {
        exitCode == 0
    }
}

protocol MacOSPreviewShellCommandRunning {
    func run(_ command: MacOSPreviewShellCommand) async throws -> MacOSPreviewShellCommandResult
}

protocol MacOSPreviewBundleInspecting {
    func identity(appURL: URL) throws -> MacOSPreviewBundleIdentity
}

protocol MacOSPreviewAppLaunching {
    func launch(appURL: URL) async throws -> MacOSPreviewLaunchedApplication
}

protocol MacOSPreviewRunningApplicationResolving {
    func runningApplications(bundleIdentifier: String) -> [MacOSPreviewRunningApplication]
}

struct MacOSPreviewWorkProofStore {
    let proofURL: URL
    var fileManager: FileManager = .default

    func write(_ proof: MacOSPreviewWorkProof) throws {
        try fileManager.createDirectory(
            at: proofURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(proof).write(to: proofURL, options: .atomic)
    }
}

enum MacOSPreviewSourceFingerprinter {
    static func snapshot(
        worktreeURL: URL,
        commandRunner: MacOSPreviewShellCommandRunning = ProcessMacOSPreviewShellCommandRunner(),
    ) async -> MacOSPreviewSourceSnapshot {
        async let head = runGit(["rev-parse", "HEAD"], worktreeURL: worktreeURL, commandRunner: commandRunner)
        async let wholeStatus = runGit(
            ["status", "--porcelain=v1"],
            worktreeURL: worktreeURL,
            commandRunner: commandRunner,
        )
        async let status = runGit(
            ["status", "--porcelain=v1", "--untracked-files=no", "--"] + previewRelevantPathspecs,
            worktreeURL: worktreeURL,
            commandRunner: commandRunner,
        )
        async let diff = runGit(
            ["diff", "--binary", "--no-ext-diff", "HEAD", "--"] + previewRelevantPathspecs,
            worktreeURL: worktreeURL,
            commandRunner: commandRunner,
        )

        let resolvedHead = await head?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWholeStatus = await wholeStatus
        let resolvedStatus = await status
        let resolvedDiff = await diff
        let dirtyState: String = if let resolvedWholeStatus {
            resolvedWholeStatus.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "clean" : "dirty"
        } else {
            "unknown"
        }
        let source = [
            "head=\(resolvedHead?.isEmpty == false ? resolvedHead! : "<unknown>")",
            "status=\(resolvedStatus ?? "<unknown>")",
            "diff=\(resolvedDiff ?? "<unknown>")",
        ].joined(separator: "\u{0}")

        return MacOSPreviewSourceSnapshot(
            gitHead: resolvedHead?.isEmpty == false ? resolvedHead : nil,
            dirtyState: dirtyState,
            fingerprint: sha256Hex(source),
        )
    }

    private static let previewRelevantPathspecs = [
        "Cargo.lock",
        "Cargo.toml",
        "apps/swift/Package.swift",
        "apps/swift/Sources",
        "core/capacitor-core/src",
        "core/hud-hook/src",
    ]

    private static func runGit(
        _ arguments: [String],
        worktreeURL: URL,
        commandRunner: MacOSPreviewShellCommandRunning,
    ) async -> String? {
        let command = MacOSPreviewShellCommand(
            executableURL: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: arguments,
            workingDirectoryURL: worktreeURL,
            outputURL: nil,
        )
        guard let result = try? await commandRunner.run(command), result.succeeded else {
            return nil
        }
        return result.output
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct MacOSPreviewWorkCoordinator {
    var commandRunner: MacOSPreviewShellCommandRunning = ProcessMacOSPreviewShellCommandRunner()
    var bundleInspector: MacOSPreviewBundleInspecting = InfoPlistMacOSPreviewBundleInspector()
    var appLauncher: MacOSPreviewAppLaunching = NSWorkspaceMacOSPreviewAppLauncher()
    var runningApplicationResolver: MacOSPreviewRunningApplicationResolving = NSWorkspaceMacOSPreviewRunningApplicationResolver()
    var fileManager: FileManager = .default
    var now: () -> Date = Date.init

    func run(_ request: MacOSPreviewWorkRequest) async throws -> MacOSPreviewWorkProof {
        let normalizedWorktreePath = normalizedPath(request.worktreeURL)
        let normalizedAppPath = normalizedPath(request.appURL)
        let buildCommand = Self.buildCommandString(for: request)
        let gitSnapshot = await MacOSPreviewSourceFingerprinter.snapshot(
            worktreeURL: request.worktreeURL,
            commandRunner: commandRunner,
        )
        let store = MacOSPreviewWorkProofStore(proofURL: request.proofURL, fileManager: fileManager)

        let buildingProof = proof(
            status: .previewBuilding,
            appPath: normalizedAppPath,
            bundleID: nil,
            displayName: nil,
            pid: nil,
            launchTime: nil,
            worktreePath: normalizedWorktreePath,
            gitHead: gitSnapshot.gitHead,
            dirtyState: gitSnapshot.dirtyState,
            sourceFingerprint: gitSnapshot.fingerprint,
            buildCommand: buildCommand,
            buildLogPath: request.buildLogURL.path,
            expectedBundleID: request.expectedBundleID,
            expectedDisplayName: request.expectedDisplayName,
            failureReason: nil,
        )
        try store.write(buildingProof)

        if let failed = alreadyRunningPreviewProof(
            request: request,
            gitSnapshot: gitSnapshot,
            buildCommand: buildCommand,
        ) {
            try store.write(failed)
            return failed
        }

        do {
            let buildResult = try await commandRunner.run(Self.buildCommand(for: request))
            guard buildResult.succeeded else {
                let failed = failedProof(
                    request: request,
                    gitSnapshot: gitSnapshot,
                    buildCommand: buildCommand,
                    reason: "Preview build failed with exit \(buildResult.exitCode).",
                )
                try store.write(failed)
                return failed
            }
        } catch {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                reason: "Preview build could not run: \(error.localizedDescription)",
            )
            try store.write(failed)
            return failed
        }

        guard fileManager.fileExists(atPath: request.appURL.path) else {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                reason: "Preview build did not produce \(request.appURL.path).",
            )
            try store.write(failed)
            return failed
        }

        let identity: MacOSPreviewBundleIdentity
        do {
            identity = try bundleInspector.identity(appURL: request.appURL)
        } catch {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                reason: "Could not read preview app identity: \(error.localizedDescription)",
            )
            try store.write(failed)
            return failed
        }

        guard identity.bundleID == request.expectedBundleID else {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                bundleID: identity.bundleID,
                displayName: identity.displayName,
                reason: "Preview bundle id mismatch: expected \(request.expectedBundleID), got \(identity.bundleID ?? "<missing>").",
            )
            try store.write(failed)
            return failed
        }

        guard identity.displayName == request.expectedDisplayName else {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                bundleID: identity.bundleID,
                displayName: identity.displayName,
                reason: "Preview display name mismatch: expected \(request.expectedDisplayName), got \(identity.displayName ?? "<missing>").",
            )
            try store.write(failed)
            return failed
        }

        if let failed = alreadyRunningPreviewProof(
            request: request,
            gitSnapshot: gitSnapshot,
            buildCommand: buildCommand,
            bundleID: identity.bundleID,
            displayName: identity.displayName,
        ) {
            try store.write(failed)
            return failed
        }

        let launched: MacOSPreviewLaunchedApplication
        do {
            launched = try await appLauncher.launch(appURL: request.appURL)
        } catch {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                bundleID: identity.bundleID,
                displayName: identity.displayName,
                reason: "Preview app could not launch: \(error.localizedDescription)",
            )
            try store.write(failed)
            return failed
        }

        let launchedPath = MacOSPreviewAppPathResolver.normalizedBundlePath(
            bundleURL: launched.bundleURL,
            executableURL: launched.executableURL,
        )
        let expectedLaunchedPath = PathNormalizer.normalize(normalizedAppPath)
        guard launchedPath == expectedLaunchedPath
        else {
            let actualPath = launchedPath
                ?? launched.bundleURL?.path
                ?? launched.executableURL?.path
                ?? "<missing>"
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                bundleID: identity.bundleID,
                displayName: identity.displayName,
                pid: launched.pid,
                launchTime: launched.launchTime,
                reason: "Launched app path mismatch: expected \(normalizedAppPath), got \(actualPath).",
            )
            try store.write(failed)
            return failed
        }

        guard launched.bundleIdentifier == request.expectedBundleID else {
            let failed = failedProof(
                request: request,
                gitSnapshot: gitSnapshot,
                buildCommand: buildCommand,
                bundleID: identity.bundleID,
                displayName: identity.displayName,
                pid: launched.pid,
                launchTime: launched.launchTime,
                reason: "Launched app bundle id mismatch: expected \(request.expectedBundleID), got \(launched.bundleIdentifier ?? "<missing>").",
            )
            try store.write(failed)
            return failed
        }

        let ready = proof(
            status: .readyToInspect,
            appPath: normalizedAppPath,
            bundleID: identity.bundleID,
            displayName: identity.displayName,
            pid: launched.pid,
            launchTime: launched.launchTime,
            worktreePath: normalizedWorktreePath,
            gitHead: gitSnapshot.gitHead,
            dirtyState: gitSnapshot.dirtyState,
            sourceFingerprint: gitSnapshot.fingerprint,
            buildCommand: buildCommand,
            buildLogPath: request.buildLogURL.path,
            expectedBundleID: request.expectedBundleID,
            expectedDisplayName: request.expectedDisplayName,
            failureReason: nil,
        )
        try store.write(ready)
        return ready
    }

    private func failedProof(
        request: MacOSPreviewWorkRequest,
        gitSnapshot: MacOSPreviewSourceSnapshot,
        buildCommand: String,
        bundleID: String? = nil,
        displayName: String? = nil,
        pid: Int32? = nil,
        launchTime: Date? = nil,
        reason: String,
    ) -> MacOSPreviewWorkProof {
        proof(
            status: .previewFailed,
            appPath: normalizedPath(request.appURL),
            bundleID: bundleID,
            displayName: displayName,
            pid: pid,
            launchTime: launchTime,
            worktreePath: normalizedPath(request.worktreeURL),
            gitHead: gitSnapshot.gitHead,
            dirtyState: gitSnapshot.dirtyState,
            sourceFingerprint: gitSnapshot.fingerprint,
            buildCommand: buildCommand,
            buildLogPath: request.buildLogURL.path,
            expectedBundleID: request.expectedBundleID,
            expectedDisplayName: request.expectedDisplayName,
            failureReason: reason,
        )
    }

    private func alreadyRunningPreviewProof(
        request: MacOSPreviewWorkRequest,
        gitSnapshot: MacOSPreviewSourceSnapshot,
        buildCommand: String,
        bundleID: String? = nil,
        displayName: String? = nil,
    ) -> MacOSPreviewWorkProof? {
        let runningPreviewApps = runningApplicationResolver.runningApplications(
            bundleIdentifier: request.expectedBundleID,
        )
        guard !runningPreviewApps.isEmpty else {
            return nil
        }

        let descriptions = runningPreviewApps
            .map { "pid=\($0.pid) path=\($0.bundleURL?.path ?? "<missing>")" }
            .joined(separator: ", ")

        return failedProof(
            request: request,
            gitSnapshot: gitSnapshot,
            buildCommand: buildCommand,
            bundleID: bundleID,
            displayName: displayName,
            reason: "Preview identity is already running: \(descriptions). Stop it before launching another preview.",
        )
    }

    private func proof(
        status: MacOSPreviewWorkStatus,
        appPath: String?,
        bundleID: String?,
        displayName: String?,
        pid: Int32?,
        launchTime: Date?,
        worktreePath: String,
        gitHead: String?,
        dirtyState: String,
        sourceFingerprint: String?,
        buildCommand: String,
        buildLogPath: String,
        expectedBundleID: String,
        expectedDisplayName: String,
        failureReason: String?,
    ) -> MacOSPreviewWorkProof {
        MacOSPreviewWorkProof(
            status: status,
            appPath: appPath,
            bundleID: bundleID,
            displayName: displayName,
            pid: pid,
            launchTime: launchTime,
            worktreePath: worktreePath,
            gitHead: gitHead,
            dirtyState: dirtyState,
            sourceFingerprint: sourceFingerprint,
            buildCommand: buildCommand,
            buildLogPath: buildLogPath,
            expectedBundleID: expectedBundleID,
            expectedDisplayName: expectedDisplayName,
            failureReason: failureReason,
            recordedAt: now(),
        )
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func buildCommand(for request: MacOSPreviewWorkRequest) -> MacOSPreviewShellCommand {
        MacOSPreviewShellCommand(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            arguments: [
                request.buildScriptURL.path,
                "--worktree",
                request.worktreeURL.path,
                "--app-path",
                request.appURL.path,
                "--bundle-id",
                request.expectedBundleID,
                "--display-name",
                request.expectedDisplayName,
            ],
            workingDirectoryURL: request.worktreeURL,
            outputURL: request.buildLogURL,
        )
    }

    static func buildCommandString(for request: MacOSPreviewWorkRequest) -> String {
        let command = buildCommand(for: request)
        return ([command.executableURL.path] + command.arguments)
            .map(shellEscape)
            .joined(separator: " ")
    }

    private static func shellEscape(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct ProcessMacOSPreviewShellCommandRunner: MacOSPreviewShellCommandRunning {
    func run(_ command: MacOSPreviewShellCommand) async throws -> MacOSPreviewShellCommandResult {
        let process = Process()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.currentDirectoryURL = command.workingDirectoryURL

        if let outputURL = command.outputURL {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            fileManager.createFile(atPath: outputURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: outputURL)
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            return MacOSPreviewShellCommandResult(exitCode: process.terminationStatus, output: nil)
        }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)
        return MacOSPreviewShellCommandResult(exitCode: process.terminationStatus, output: output)
    }
}

struct InfoPlistMacOSPreviewBundleInspector: MacOSPreviewBundleInspecting {
    enum Error: LocalizedError {
        case missingInfoPlist(String)
        case invalidInfoPlist(String)

        var errorDescription: String? {
            switch self {
            case let .missingInfoPlist(path):
                "Missing Info.plist at \(path)."
            case let .invalidInfoPlist(path):
                "Invalid Info.plist at \(path)."
            }
        }
    }

    func identity(appURL: URL) throws -> MacOSPreviewBundleIdentity {
        let infoPlistURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        guard FileManager.default.fileExists(atPath: infoPlistURL.path) else {
            throw Error.missingInfoPlist(infoPlistURL.path)
        }

        let data = try Data(contentsOf: infoPlistURL)
        guard let dictionary = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil,
        ) as? [String: Any]
        else {
            throw Error.invalidInfoPlist(infoPlistURL.path)
        }

        return MacOSPreviewBundleIdentity(
            bundleID: dictionary["CFBundleIdentifier"] as? String,
            displayName: (dictionary["CFBundleDisplayName"] as? String) ?? (dictionary["CFBundleName"] as? String),
        )
    }
}

struct NSWorkspaceMacOSPreviewAppLauncher: MacOSPreviewAppLaunching {
    func launch(appURL: URL) async throws -> MacOSPreviewLaunchedApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true

        let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let application {
                    continuation.resume(returning: application)
                } else {
                    continuation.resume(throwing: CocoaError(.fileNoSuchFile))
                }
            }
        }

        return MacOSPreviewLaunchedApplication(
            pid: app.processIdentifier,
            bundleURL: app.bundleURL,
            bundleIdentifier: app.bundleIdentifier,
            localizedName: app.localizedName,
            launchTime: Date(),
            executableURL: app.executableURL,
        )
    }
}

struct NSWorkspaceMacOSPreviewRunningApplicationResolver: MacOSPreviewRunningApplicationResolving {
    func runningApplications(bundleIdentifier: String) -> [MacOSPreviewRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .map {
                MacOSPreviewRunningApplication(
                    pid: $0.processIdentifier,
                    bundleURL: $0.bundleURL,
                    executableURL: $0.executableURL,
                )
            }
    }
}

enum MacOSPreviewAppPathResolver {
    static func normalizedBundlePath(bundleURL: URL?, executableURL: URL?) -> String? {
        if let bundleURL {
            return PathNormalizer.normalize(bundleURL.path)
        }

        guard let bundleURL = bundleURLContaining(executableURL: executableURL) else {
            return nil
        }
        return PathNormalizer.normalize(bundleURL.path)
    }

    private static func bundleURLContaining(executableURL: URL?) -> URL? {
        guard var candidate = executableURL?.standardizedFileURL else { return nil }
        while !candidate.path.isEmpty, candidate.path != "/" {
            if candidate.pathExtension == "app" {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}

import Foundation

actor RunCaptureCoordinator {
    typealias RunMutator = @Sendable (RuntimeRunMutationRequest) async throws -> Void

    private enum RecoveryMode {
        case pending
        case ownedInProgress(captureRequestID: String)
    }

    private struct CaptureCandidate {
        let run: RuntimeRunState
        let checkpoint: RuntimeCheckpointState
        let captureURL: String
        let recoveryMode: RecoveryMode
    }

    private enum LocalArtifactError: Error, LocalizedError {
        case missingFile(path: String)

        var errorDescription: String? {
            switch self {
            case let .missingFile(path):
                "Expected local artifact was not written: \(path)"
            }
        }
    }

    private let runtimeMutation: RunMutator
    private let captureURL: @Sendable (String, String) async throws -> WebCaptureService.CaptureResult
    private let captureMermaid: @Sendable (String, String) async throws -> WebCaptureService.CaptureResult
    private let closeBrowser: @Sendable () async -> Void
    private let isCaptureToolAvailable: @Sendable () async -> Bool
    private let fileManager: FileManager
    private let homeDirectoryProvider: @Sendable () -> URL
    private let clientID: String
    private var inFlightCheckpointIDs: Set<String> = []

    private static let defaultHomeDirectoryProvider: @Sendable () -> URL = {
        FileManager.default.homeDirectoryForCurrentUser
    }

    init(
        runtimeClient: RuntimeClient,
        captureService: WebCaptureService = WebCaptureService(),
        fileManager: FileManager = .default,
        homeDirectoryProvider: @escaping @Sendable () -> URL = defaultHomeDirectoryProvider,
        clientID: String = RunCaptureCoordinator.defaultClientID(),
    ) {
        runtimeMutation = Self.makeRunMutator(runtimeClient: runtimeClient)
        captureURL = Self.makeURLCaptureHandler(captureService: captureService)
        captureMermaid = Self.makeMermaidCaptureHandler(captureService: captureService)
        closeBrowser = Self.makeCloseBrowserHandler(captureService: captureService)
        isCaptureToolAvailable = Self.makeCaptureAvailabilityChecker(captureService: captureService)
        self.fileManager = fileManager
        self.homeDirectoryProvider = homeDirectoryProvider
        self.clientID = clientID
    }

    init(
        mutateRun: @escaping RunMutator,
        captureURL: @escaping @Sendable (String, String) async throws -> WebCaptureService.CaptureResult,
        captureMermaid: @escaping @Sendable (String, String) async throws -> WebCaptureService.CaptureResult,
        closeBrowser: @escaping @Sendable () async -> Void,
        isCaptureToolAvailable: @escaping @Sendable () async -> Bool,
        fileManager: FileManager = .default,
        homeDirectoryProvider: @escaping @Sendable () -> URL,
        clientID: String = RunCaptureCoordinator.defaultClientID(),
    ) {
        runtimeMutation = mutateRun
        self.captureURL = captureURL
        self.captureMermaid = captureMermaid
        self.closeBrowser = closeBrowser
        self.isCaptureToolAvailable = isCaptureToolAvailable
        self.fileManager = fileManager
        self.homeDirectoryProvider = homeDirectoryProvider
        self.clientID = clientID
    }

    private static func defaultClientID() -> String {
        "capacitor-mac-\(ProcessInfo.processInfo.processIdentifier)"
    }

    private static func makeRunMutator(runtimeClient: RuntimeClient) -> RunMutator {
        { request in
            try await runtimeClient.mutateRun(request)
        }
    }

    private static func makeURLCaptureHandler(
        captureService: WebCaptureService,
    ) -> @Sendable (String, String) async throws -> WebCaptureService.CaptureResult {
        { url, outputPath in
            try await captureService.captureURL(url, outputPath: outputPath)
        }
    }

    private static func makeMermaidCaptureHandler(
        captureService: WebCaptureService,
    ) -> @Sendable (String, String) async throws -> WebCaptureService.CaptureResult {
        { source, outputPath in
            try await captureService.captureMermaid(source: source, outputPath: outputPath)
        }
    }

    private static func makeCloseBrowserHandler(
        captureService: WebCaptureService,
    ) -> @Sendable () async -> Void {
        {
            await captureService.closeBrowser()
        }
    }

    private static func makeCaptureAvailabilityChecker(
        captureService: WebCaptureService,
    ) -> @Sendable () async -> Bool {
        {
            await captureService.isAvailable()
        }
    }

    func reconcile(runs: [RuntimeRunState]) async {
        for run in runs {
            guard let candidate = captureCandidate(for: run) else { continue }
            await reconcile(candidate)
        }
    }

    private func captureCandidate(for run: RuntimeRunState) -> CaptureCandidate? {
        guard let checkpoint = run.activeCheckpoint else { return nil }
        guard !inFlightCheckpointIDs.contains(checkpoint.id) else { return nil }

        switch checkpoint.captureStatus {
        case .pending:
            guard let captureURL = normalizedCaptureURL(checkpoint.captureUrl) else { return nil }
            return CaptureCandidate(
                run: run,
                checkpoint: checkpoint,
                captureURL: captureURL,
                recoveryMode: .pending,
            )

        case .inProgress:
            guard let claim = checkpoint.captureClaim else {
                DebugLog.write(
                    "RunCaptureCoordinator.reconcile skipped reason=missing_claim checkpoint=\(checkpoint.id) run=\(run.id)",
                )
                return nil
            }
            guard claim.clientId == clientID else { return nil }
            guard let captureURL = normalizedCaptureURL(checkpoint.captureUrl) else { return nil }
            return CaptureCandidate(
                run: run,
                checkpoint: checkpoint,
                captureURL: captureURL,
                recoveryMode: .ownedInProgress(captureRequestID: claim.captureRequestId),
            )

        case .notRequested, .completed, .failed:
            return nil
        }
    }

    private func reconcile(_ candidate: CaptureCandidate) async {
        guard inFlightCheckpointIDs.insert(candidate.checkpoint.id).inserted else { return }

        let captureRequestID: String
        let shouldClaim: Bool
        switch candidate.recoveryMode {
        case .pending:
            captureRequestID = UUID().uuidString.lowercased()
            shouldClaim = true
        case let .ownedInProgress(existingID):
            captureRequestID = existingID
            shouldClaim = false
        }

        await processCandidate(
            candidate,
            captureRequestID: captureRequestID,
            shouldClaim: shouldClaim,
        )
        await closeBrowser()
        inFlightCheckpointIDs.remove(candidate.checkpoint.id)
    }

    private func processCandidate(
        _ candidate: CaptureCandidate,
        captureRequestID: String,
        shouldClaim: Bool,
    ) async {
        if shouldClaim {
            do {
                try await runtimeMutation(
                    makeMutationRequest(
                        kind: "capture_claim",
                        run: candidate.run,
                        checkpointID: candidate.checkpoint.id,
                        captureRequestID: captureRequestID,
                        clientID: clientID,
                        observedCaptureURL: candidate.captureURL,
                    ),
                )
            } catch let error as RuntimeClientError {
                if case .mutationRejected = error {
                    DebugLog.write(
                        "RunCaptureCoordinator.reconcile skipped reason=claim_rejected checkpoint=\(candidate.checkpoint.id) run=\(candidate.run.id)",
                    )
                } else {
                    DebugLog.write(
                        "RunCaptureCoordinator.claim failed checkpoint=\(candidate.checkpoint.id) run=\(candidate.run.id) error=\(error)",
                    )
                }
                return
            } catch {
                DebugLog.write(
                    "RunCaptureCoordinator.claim failed checkpoint=\(candidate.checkpoint.id) run=\(candidate.run.id) error=\(error.localizedDescription)",
                )
                return
            }
        }

        let captureDirectory = captureDirectoryURL(
            runID: candidate.run.id,
            checkpointID: candidate.checkpoint.id,
        )

        // On ownedInProgress recovery, try to finalize from preserved artifacts first.
        // A previous capture may have succeeded locally but failed to finalize due to
        // transport failure. If the artifacts are still on disk, skip the browser entirely.
        if !shouldClaim, let preservedArtifacts = recoverPreservedArtifacts(
            for: candidate,
            captureDirectory: captureDirectory,
        ) {
            do {
                try await runtimeMutation(
                    makeMutationRequest(
                        kind: "capture_complete",
                        run: candidate.run,
                        checkpointID: candidate.checkpoint.id,
                        captureRequestID: captureRequestID,
                        completedMediaArtifacts: preservedArtifacts,
                    ),
                )
                DebugLog.write(
                    "RunCaptureCoordinator.finalize recovered from preserved artifacts checkpoint=\(candidate.checkpoint.id) run=\(candidate.run.id) artifacts=\(preservedArtifacts.count)",
                )
                return
            } catch {
                cleanupAfterFinalizationFailure(
                    captureDirectory: captureDirectory,
                    checkpointID: candidate.checkpoint.id,
                    runID: candidate.run.id,
                    error: error,
                )
                return
            }
        }

        let isToolAvailable = await isCaptureToolAvailable()
        guard isToolAvailable else {
            await finalizeFailedCapture(
                candidate,
                captureRequestID: captureRequestID,
                reason: "tool_unavailable",
                captureDirectory: captureDirectory,
            )
            return
        }

        do {
            let artifacts = try await buildArtifacts(
                for: candidate,
                captureDirectory: captureDirectory,
            )
            do {
                try await runtimeMutation(
                    makeMutationRequest(
                        kind: "capture_complete",
                        run: candidate.run,
                        checkpointID: candidate.checkpoint.id,
                        captureRequestID: captureRequestID,
                        completedMediaArtifacts: artifacts,
                    ),
                )
            } catch {
                cleanupAfterFinalizationFailure(
                    captureDirectory: captureDirectory,
                    checkpointID: candidate.checkpoint.id,
                    runID: candidate.run.id,
                    error: error,
                )
            }
        } catch {
            await finalizeFailedCapture(
                candidate,
                captureRequestID: captureRequestID,
                reason: localFailureReason(for: error),
                captureDirectory: captureDirectory,
            )
        }
    }

    private func buildArtifacts(
        for candidate: CaptureCandidate,
        captureDirectory: URL,
    ) async throws -> [RuntimeMediaArtifact] {
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)

        let webCapturePath = captureDirectory.appendingPathComponent("web-capture.png")
        let webCaptureResult = try await captureURL(candidate.captureURL, webCapturePath.path)
        try ensureFileExists(at: webCapturePath)

        var artifacts = [
            RuntimeMediaArtifact(
                artifactType: "screenshot",
                path: webCaptureResult.imagePath,
                label: "Web capture",
                width: webCaptureResult.width,
                height: webCaptureResult.height,
                durationSecs: nil,
            ),
        ]

        for (index, source) in candidate.checkpoint.mermaidSources.enumerated() {
            let mermaidSourcePath = captureDirectory.appendingPathComponent("mermaid-\(index).mmd")
            let mermaidImagePath = captureDirectory.appendingPathComponent("mermaid-\(index).png")
            try source.source.write(to: mermaidSourcePath, atomically: true, encoding: .utf8)
            let mermaidResult = try await captureMermaid(source.source, mermaidImagePath.path)
            try ensureFileExists(at: mermaidSourcePath)
            try ensureFileExists(at: mermaidImagePath)

            artifacts.append(
                RuntimeMediaArtifact(
                    artifactType: "mermaid_diagram",
                    path: mermaidResult.imagePath,
                    label: source.label,
                    width: mermaidResult.width,
                    height: mermaidResult.height,
                    durationSecs: nil,
                ),
            )
        }

        return artifacts
    }

    /// Checks whether a previous capture attempt left a complete artifact set on disk.
    /// Returns a reconstructed artifact list if all expected artifacts exist and are
    /// non-empty, or nil if any are missing/incomplete — triggering a fresh capture.
    private func recoverPreservedArtifacts(
        for candidate: CaptureCandidate,
        captureDirectory: URL,
    ) -> [RuntimeMediaArtifact]? {
        let webCapturePath = captureDirectory.appendingPathComponent("web-capture.png")
        guard isNonEmptyFile(at: webCapturePath) else {
            DebugLog.write(
                "RunCaptureCoordinator.recoverPreservedArtifacts skipped reason=web_capture_missing_or_empty checkpoint=\(candidate.checkpoint.id)",
            )
            return nil
        }

        var artifacts = [
            RuntimeMediaArtifact(
                artifactType: "screenshot",
                path: webCapturePath.path,
                label: "Web capture",
                width: nil,
                height: nil,
                durationSecs: nil,
            ),
        ]

        for (index, source) in candidate.checkpoint.mermaidSources.enumerated() {
            let mermaidImagePath = captureDirectory.appendingPathComponent("mermaid-\(index).png")
            guard isNonEmptyFile(at: mermaidImagePath) else {
                DebugLog.write(
                    "RunCaptureCoordinator.recoverPreservedArtifacts skipped reason=mermaid_\(index)_missing_or_empty checkpoint=\(candidate.checkpoint.id)",
                )
                return nil
            }
            artifacts.append(
                RuntimeMediaArtifact(
                    artifactType: "mermaid_diagram",
                    path: mermaidImagePath.path,
                    label: source.label,
                    width: nil,
                    height: nil,
                    durationSecs: nil,
                ),
            )
        }

        return artifacts
    }

    private func isNonEmptyFile(at url: URL) -> Bool {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
            return false
        }
        let fileType = attributes[.type] as? FileAttributeType
        guard fileType == .typeRegular else { return false }
        let size = attributes[.size] as? UInt64 ?? 0
        return size > 0
    }

    private func finalizeFailedCapture(
        _ candidate: CaptureCandidate,
        captureRequestID: String,
        reason: String,
        captureDirectory: URL,
    ) async {
        deleteCaptureDirectoryIfPresent(captureDirectory)

        do {
            try await runtimeMutation(
                makeMutationRequest(
                    kind: "capture_failed",
                    run: candidate.run,
                    checkpointID: candidate.checkpoint.id,
                    captureRequestID: captureRequestID,
                    captureFailureReason: reason,
                ),
            )
        } catch {
            DebugLog.write(
                "RunCaptureCoordinator.captureFailed finalize failed checkpoint=\(candidate.checkpoint.id) run=\(candidate.run.id) reason=\(reason) error=\(error.localizedDescription)",
            )
        }
    }

    private func cleanupAfterFinalizationFailure(
        captureDirectory _: URL,
        checkpointID: String,
        runID: String,
        error: Error,
    ) {
        DebugLog.write(
            "RunCaptureCoordinator.finalize failed checkpoint=\(checkpointID) run=\(runID) error=\(error.localizedDescription)",
        )
    }

    private func deleteCaptureDirectoryIfPresent(_ captureDirectory: URL) {
        guard fileManager.fileExists(atPath: captureDirectory.path) else { return }

        do {
            try fileManager.removeItem(at: captureDirectory)
        } catch {
            DebugLog.write(
                "RunCaptureCoordinator.cleanup failed path=\(captureDirectory.path) error=\(error.localizedDescription)",
            )
        }
    }

    private func ensureFileExists(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            throw LocalArtifactError.missingFile(path: url.path)
        }
    }

    private func captureDirectoryURL(runID: String, checkpointID: String) -> URL {
        homeDirectoryProvider()
            .appendingPathComponent(".capacitor", isDirectory: true)
            .appendingPathComponent("runtime", isDirectory: true)
            .appendingPathComponent("captures", isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(runID), isDirectory: true)
            .appendingPathComponent(sanitizedPathComponent(checkpointID), isDirectory: true)
    }

    private func makeMutationRequest(
        kind: String,
        run: RuntimeRunState,
        checkpointID: String,
        captureRequestID: String? = nil,
        clientID: String? = nil,
        observedCaptureURL: String? = nil,
        captureFailureReason: String? = nil,
        completedMediaArtifacts: [RuntimeMediaArtifact] = [],
    ) -> RuntimeRunMutationRequest {
        RuntimeRunMutationRequest(
            kind: kind,
            projectPath: run.projectPath,
            runId: run.id,
            checkpointId: checkpointID,
            methodId: nil,
            involvement: nil,
            checkpointKind: nil,
            checkpointTitle: nil,
            checkpointSummary: nil,
            checkpointBriefPath: nil,
            checkpointManifestPath: nil,
            checkpointMediaArtifacts: [],
            checkpointMermaidSources: [],
            captureUrl: nil,
            decisionAction: nil,
            decisionNote: nil,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: nil,
            captureRequestId: captureRequestID,
            clientId: clientID,
            observedCaptureUrl: observedCaptureURL,
            captureFailureReason: captureFailureReason,
            completedMediaArtifacts: completedMediaArtifacts,
            ideaId: nil,
            ideaTitle: nil,
            ideaDescription: nil,
        )
    }

    private func normalizedCaptureURL(_ captureURL: String?) -> String? {
        guard let captureURL else { return nil }
        let trimmed = captureURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sanitizedPathComponent(_ value: String) -> String {
        value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
    }

    private func localFailureReason(for error: Error) -> String {
        if let captureError = error as? WebCaptureService.CaptureError {
            return captureErrorReason(captureError)
        }

        // Distinguish filesystem/artifact failures from truly unexpected errors
        let description = trimmedReasonText(error.localizedDescription)
        if (error as NSError).domain == NSCocoaErrorDomain || error is CocoaError {
            return "artifact_write_failed:\(description)"
        }
        return "unexpected_error:\(description)"
    }

    private func captureErrorReason(_ error: WebCaptureService.CaptureError) -> String {
        switch error {
        case .agentBrowserNotFound:
            "tool_unavailable"
        case .timeout:
            "timeout"
        case let .navigationFailed(_, stderr):
            "navigation_failed:\(trimmedReasonText(stderr))"
        case let .screenshotFailed(stderr):
            "screenshot_failed:\(trimmedReasonText(stderr))"
        case let .outputFileMissing(path):
            "output_file_missing:\(trimmedReasonText(path))"
        }
    }

    private func trimmedReasonText(_ value: String) -> String {
        let compact = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        if compact.count > 200 {
            return String(compact.prefix(200))
        }
        return compact
    }
}

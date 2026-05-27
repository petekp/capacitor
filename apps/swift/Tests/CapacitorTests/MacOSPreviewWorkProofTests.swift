#if DEBUG
    import AppKit
    @testable import Capacitor
    import Foundation
    import XCTest

    final class MacOSPreviewWorkProofTests: XCTestCase {
        func testBuildCommandUsesExplicitPreviewContract() {
            let worktree = URL(fileURLWithPath: "/tmp/capacitor-worktree", isDirectory: true)
            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: worktree,
                proofDirectoryURL: worktree.appendingPathComponent("proof", isDirectory: true),
                buildScriptURL: worktree.appendingPathComponent("scripts/dev/build-preview-app.sh"),
            )

            let command = MacOSPreviewWorkCoordinator.buildCommand(for: request)

            XCTAssertEqual(command.executableURL.path, "/bin/bash")
            XCTAssertEqual(command.workingDirectoryURL.path, "/tmp/capacitor-worktree")
            XCTAssertEqual(command.outputURL?.path, "/tmp/capacitor-worktree/proof/latest-build.log")
            XCTAssertEqual(command.arguments, [
                "/tmp/capacitor-worktree/scripts/dev/build-preview-app.sh",
                "--worktree",
                "/tmp/capacitor-worktree",
                "--app-path",
                "/tmp/capacitor-worktree/apps/swift/CapacitorPreview.app",
                "--bundle-id",
                "com.capacitor.app.preview",
                "--display-name",
                "Capacitor Preview",
            ])
        }

        func testRealCapacitorPreviewBuildLaunchProof() async throws {
            guard ProcessInfo.processInfo.environment["CAPACITOR_RUN_MACOS_PREVIEW_PROOF"] == "1" else {
                throw XCTSkip("Set CAPACITOR_RUN_MACOS_PREVIEW_PROOF=1 to build and launch the real Capacitor Preview app.")
            }

            let root = ReceiptFirstProofArtifacts.defaultCapacitorRoot()
            let proofDirectory = root.appendingPathComponent(
                "docs/circuit/proofs/operator-product-loop/macos-preview-work",
                isDirectory: true,
            )
            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: root,
                proofDirectoryURL: proofDirectory,
            )

            try await Self.terminateRunningPreviewApps(bundleID: request.expectedBundleID)

            let proof = try await MacOSPreviewWorkCoordinator().run(request)

            XCTAssertEqual(proof.status, .readyToInspect)
            XCTAssertEqual(proof.bundleID, "com.capacitor.app.preview")
            XCTAssertEqual(proof.displayName, "Capacitor Preview")
            XCTAssertEqual(proof.appPath, request.appURL.path)
            XCTAssertNotNil(proof.pid)
            XCTAssertNil(proof.failureReason)
        }

        func testReadyProofRequiresExactPreviewIdentityAndLaunchPath() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: directory,
                proofDirectoryURL: directory.appendingPathComponent("proof", isDirectory: true),
            )
            let launchTime = Date(timeIntervalSince1970: 1_779_914_400)
            let runner = FakePreviewCommandRunner { command in
                if command.executableURL.path == "/usr/bin/git" {
                    if command.arguments == ["rev-parse", "HEAD"] {
                        return MacOSPreviewShellCommandResult(exitCode: 0, output: "abc123\n")
                    }
                    if command.arguments == ["status", "--porcelain"] {
                        return MacOSPreviewShellCommandResult(exitCode: 0, output: "")
                    }
                }
                if command.executableURL.path == "/bin/bash" {
                    try Self.writeAppBundle(
                        at: request.appURL,
                        bundleID: request.expectedBundleID,
                        displayName: request.expectedDisplayName,
                    )
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: nil)
                }
                XCTFail("Unexpected command: \(command)")
                return MacOSPreviewShellCommandResult(exitCode: 1, output: nil)
            }
            let launcher = FakePreviewAppLauncher { appURL in
                MacOSPreviewLaunchedApplication(
                    pid: 4242,
                    bundleURL: appURL,
                    bundleIdentifier: request.expectedBundleID,
                    localizedName: request.expectedDisplayName,
                    launchTime: launchTime,
                )
            }
            let coordinator = MacOSPreviewWorkCoordinator(
                commandRunner: runner,
                appLauncher: launcher,
                runningApplicationResolver: FakeRunningApplicationResolver(),
                now: { Date(timeIntervalSince1970: 1_779_914_401) },
            )

            let proof = try await coordinator.run(request)

            XCTAssertEqual(proof.status, .readyToInspect)
            XCTAssertEqual(proof.appPath, request.appURL.path)
            XCTAssertEqual(proof.bundleID, "com.capacitor.app.preview")
            XCTAssertEqual(proof.displayName, "Capacitor Preview")
            XCTAssertEqual(proof.pid, 4242)
            XCTAssertEqual(proof.launchTime, launchTime)
            XCTAssertEqual(proof.gitHead, "abc123")
            XCTAssertEqual(proof.dirtyState, "clean")
            XCTAssertNil(proof.failureReason)

            let data = try Data(contentsOf: request.proofURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .capacitorISO8601
            let decoded = try decoder.decode(MacOSPreviewWorkProof.self, from: data)
            XCTAssertEqual(decoded, proof)
        }

        func testReadyProofResolvesLaunchPathFromExecutableURLWhenBundleURLIsMissing() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: directory,
                proofDirectoryURL: directory.appendingPathComponent("proof", isDirectory: true),
            )
            let executableURL = request.appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("MacOS", isDirectory: true)
                .appendingPathComponent("Capacitor")
            let runner = FakePreviewCommandRunner { command in
                if command.executableURL.path == "/usr/bin/git" {
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: "")
                }
                if command.executableURL.path == "/bin/bash" {
                    try Self.writeAppBundle(
                        at: request.appURL,
                        bundleID: request.expectedBundleID,
                        displayName: request.expectedDisplayName,
                    )
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: nil)
                }
                return MacOSPreviewShellCommandResult(exitCode: 1, output: nil)
            }
            let launcher = FakePreviewAppLauncher { _ in
                MacOSPreviewLaunchedApplication(
                    pid: 9876,
                    bundleURL: nil,
                    bundleIdentifier: request.expectedBundleID,
                    localizedName: request.expectedDisplayName,
                    launchTime: Date(timeIntervalSince1970: 1_779_914_403),
                    executableURL: executableURL,
                )
            }
            let coordinator = MacOSPreviewWorkCoordinator(
                commandRunner: runner,
                appLauncher: launcher,
                runningApplicationResolver: FakeRunningApplicationResolver(),
            )

            let proof = try await coordinator.run(request)

            XCTAssertEqual(proof.status, .readyToInspect)
            XCTAssertEqual(proof.appPath, request.appURL.path)
            XCTAssertEqual(proof.pid, 9876)
            XCTAssertNil(proof.failureReason)
        }

        func testFailsClosedWhenBundleIdentifierDoesNotMatch() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: directory,
                proofDirectoryURL: directory.appendingPathComponent("proof", isDirectory: true),
            )
            let runner = FakePreviewCommandRunner { command in
                if command.executableURL.path == "/usr/bin/git" {
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: "")
                }
                if command.executableURL.path == "/bin/bash" {
                    try Self.writeAppBundle(
                        at: request.appURL,
                        bundleID: "com.capacitor.app.debug",
                        displayName: request.expectedDisplayName,
                    )
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: nil)
                }
                return MacOSPreviewShellCommandResult(exitCode: 1, output: nil)
            }
            let launcher = FakePreviewAppLauncher { _ in
                XCTFail("Bundle mismatch must fail before launch")
                return MacOSPreviewLaunchedApplication(
                    pid: 1,
                    bundleURL: request.appURL,
                    bundleIdentifier: request.expectedBundleID,
                    localizedName: request.expectedDisplayName,
                    launchTime: Date(),
                )
            }
            let coordinator = MacOSPreviewWorkCoordinator(
                commandRunner: runner,
                appLauncher: launcher,
                runningApplicationResolver: FakeRunningApplicationResolver(),
            )

            let proof = try await coordinator.run(request)

            XCTAssertEqual(proof.status, .previewFailed)
            XCTAssertEqual(proof.bundleID, "com.capacitor.app.debug")
            XCTAssertNil(proof.pid)
            XCTAssertTrue(proof.failureReason?.contains("bundle id mismatch") == true)
        }

        func testFailsClosedWhenLaunchReturnsDifferentAppPath() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: directory,
                proofDirectoryURL: directory.appendingPathComponent("proof", isDirectory: true),
            )
            let otherAppURL = directory.appendingPathComponent("Other.app", isDirectory: true)
            let runner = FakePreviewCommandRunner { command in
                if command.executableURL.path == "/usr/bin/git" {
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: "")
                }
                if command.executableURL.path == "/bin/bash" {
                    try Self.writeAppBundle(
                        at: request.appURL,
                        bundleID: request.expectedBundleID,
                        displayName: request.expectedDisplayName,
                    )
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: nil)
                }
                return MacOSPreviewShellCommandResult(exitCode: 1, output: nil)
            }
            let launcher = FakePreviewAppLauncher { _ in
                MacOSPreviewLaunchedApplication(
                    pid: 5678,
                    bundleURL: otherAppURL,
                    bundleIdentifier: request.expectedBundleID,
                    localizedName: request.expectedDisplayName,
                    launchTime: Date(timeIntervalSince1970: 1_779_914_402),
                )
            }
            let coordinator = MacOSPreviewWorkCoordinator(
                commandRunner: runner,
                appLauncher: launcher,
                runningApplicationResolver: FakeRunningApplicationResolver(),
            )

            let proof = try await coordinator.run(request)

            XCTAssertEqual(proof.status, .previewFailed)
            XCTAssertEqual(proof.pid, 5678)
            XCTAssertTrue(proof.failureReason?.contains("path mismatch") == true)
        }

        func testFailsClosedWhenPreviewIdentityIsAlreadyRunning() async throws {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }

            let request = MacOSPreviewWorkRequest.capacitorPreview(
                worktreeURL: directory,
                proofDirectoryURL: directory.appendingPathComponent("proof", isDirectory: true),
            )
            let runner = FakePreviewCommandRunner { command in
                if command.executableURL.path == "/usr/bin/git" {
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: "")
                }
                if command.executableURL.path == "/bin/bash" {
                    XCTFail("Already-running preview identity must fail before build")
                    return MacOSPreviewShellCommandResult(exitCode: 0, output: nil)
                }
                return MacOSPreviewShellCommandResult(exitCode: 1, output: nil)
            }
            let launcher = FakePreviewAppLauncher { _ in
                XCTFail("Already-running preview identity must fail before launch")
                return MacOSPreviewLaunchedApplication(
                    pid: 1,
                    bundleURL: request.appURL,
                    bundleIdentifier: request.expectedBundleID,
                    localizedName: request.expectedDisplayName,
                    launchTime: Date(),
                )
            }
            let resolver = FakeRunningApplicationResolver(apps: [
                MacOSPreviewRunningApplication(
                    pid: 999,
                    bundleURL: request.appURL,
                ),
            ])
            let coordinator = MacOSPreviewWorkCoordinator(
                commandRunner: runner,
                appLauncher: launcher,
                runningApplicationResolver: resolver,
            )

            let proof = try await coordinator.run(request)

            XCTAssertEqual(proof.status, .previewFailed)
            XCTAssertTrue(proof.failureReason?.contains("already running") == true)
            XCTAssertNil(proof.pid)
        }

        private static func writeAppBundle(
            at appURL: URL,
            bundleID: String,
            displayName: String,
        ) throws {
            let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(
                at: contentsURL.appendingPathComponent("MacOS", isDirectory: true),
                withIntermediateDirectories: true,
            )
            let plist: [String: Any] = [
                "CFBundleExecutable": "Capacitor",
                "CFBundleIdentifier": bundleID,
                "CFBundleName": displayName,
                "CFBundleDisplayName": displayName,
                "CFBundlePackageType": "APPL",
            ]
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist,
                format: .xml,
                options: 0,
            )
            try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
        }

        private func temporaryDirectory() -> URL {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacOSPreviewWorkProofTests-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        private static func terminateRunningPreviewApps(bundleID: String) async throws {
            let existingApps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            for app in existingApps {
                app.terminate()
            }

            if try await waitUntilNoPreviewApps(bundleID: bundleID, timeout: 5) {
                return
            }

            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.forceTerminate()
            }

            if try await waitUntilNoPreviewApps(bundleID: bundleID, timeout: 5) == false {
                throw NSError(
                    domain: "MacOSPreviewWorkProofTests",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not stop existing \(bundleID) preview app before proof run.",
                    ],
                )
            }
        }

        private static func waitUntilNoPreviewApps(bundleID: String, timeout: TimeInterval) async throws -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
                    return true
                }
                try await _Concurrency.Task.sleep(nanoseconds: 250_000_000)
            }
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        }
    }

    private final class FakePreviewCommandRunner: MacOSPreviewShellCommandRunning {
        private let handler: (MacOSPreviewShellCommand) throws -> MacOSPreviewShellCommandResult

        init(handler: @escaping (MacOSPreviewShellCommand) throws -> MacOSPreviewShellCommandResult) {
            self.handler = handler
        }

        func run(_ command: MacOSPreviewShellCommand) async throws -> MacOSPreviewShellCommandResult {
            try handler(command)
        }
    }

    private struct FakePreviewAppLauncher: MacOSPreviewAppLaunching {
        let handler: (URL) throws -> MacOSPreviewLaunchedApplication

        func launch(appURL: URL) async throws -> MacOSPreviewLaunchedApplication {
            try handler(appURL)
        }
    }

    private struct FakeRunningApplicationResolver: MacOSPreviewRunningApplicationResolving {
        var apps: [MacOSPreviewRunningApplication] = []

        func runningApplications(bundleIdentifier _: String) -> [MacOSPreviewRunningApplication] {
            apps
        }
    }
#endif

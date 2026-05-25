@testable import Capacitor
import XCTest

final class MethodRunCoordinatorTests: XCTestCase {
    func testStartRunWritesIntentContextBeforeLaunchingMethodRunner() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runnerURL = directory.appendingPathComponent("method-runner")
        try writeFakeMethodRunner(to: runnerURL)
        let previousRunnerPath = ProcessInfo.processInfo.environment["METHOD_RUNNER_PATH"]
        setenv("METHOD_RUNNER_PATH", runnerURL.path, 1)
        defer {
            if let previousRunnerPath {
                setenv("METHOD_RUNNER_PATH", previousRunnerPath, 1)
            } else {
                unsetenv("METHOD_RUNNER_PATH")
            }
        }

        let coordinator = MethodRunCoordinator(
            mutateRun: { _ in },
            capacitorRoot: directory.appendingPathComponent("capacitor-home").path,
        )

        try await coordinator.startRun(
            runID: "run-context-write",
            methodID: "execution_only",
            projectPath: directory.path,
            ideaTitle: "Improve checkpoint evidence packets",
            ideaDescription: "Keep diffs behind disclosure.",
            ideaIntent: "Improve checkpoint evidence packets",
            ideaSuccessCriteria: "The owner can decide from the brief.",
            timeoutSeconds: 1,
        )

        let contextURL = directory
            .appendingPathComponent("capacitor-home/runs/run-context-write/context.json")
        let contextData = try Data(contentsOf: contextURL)
        let context = try XCTUnwrap(JSONSerialization.jsonObject(with: contextData) as? [String: Any])
        XCTAssertEqual(context["intent"] as? String, "Improve checkpoint evidence packets")
        XCTAssertEqual(context["success_criteria"] as? String, "The owner can decide from the brief.")
    }

    func testStartRunFailsWhenIntentContextCannotBeWritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let runnerURL = directory.appendingPathComponent("method-runner")
        try writeFakeMethodRunner(to: runnerURL)
        let previousRunnerPath = ProcessInfo.processInfo.environment["METHOD_RUNNER_PATH"]
        setenv("METHOD_RUNNER_PATH", runnerURL.path, 1)
        defer {
            if let previousRunnerPath {
                setenv("METHOD_RUNNER_PATH", previousRunnerPath, 1)
            } else {
                unsetenv("METHOD_RUNNER_PATH")
            }
        }

        let blockedRoot = directory.appendingPathComponent("not-a-directory")
        try Data("file blocks run directory".utf8).write(to: blockedRoot)
        let recorder = MutationRecorder()
        let coordinator = MethodRunCoordinator(
            mutateRun: { request in
                await recorder.append(request)
            },
            capacitorRoot: blockedRoot.path,
        )

        do {
            try await coordinator.startRun(
                runID: "run-context-blocked",
                methodID: "execution_only",
                projectPath: directory.path,
                ideaTitle: "Improve checkpoint evidence packets",
                ideaDescription: "Keep diffs behind disclosure.",
                ideaIntent: "Improve checkpoint evidence packets",
                ideaSuccessCriteria: "The owner can decide from the brief.",
                timeoutSeconds: 1,
            )
            XCTFail("Expected startRun to fail before launching without context.")
        } catch MethodRunError.contextUnavailable {
            // Expected.
        } catch {
            XCTFail("Expected contextUnavailable, got \(error).")
        }

        let requests = await recorder.allRequests()
        XCTAssertEqual(requests.map(\.kind), ["fail"])
        XCTAssertEqual(requests.first?.projectPath, directory.path)
        XCTAssertEqual(requests.first?.runId, "run-context-blocked")
        XCTAssertEqual(requests.first?.statusMessage, "method-runner context could not be prepared.")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("method-run-coordinator-\(UUID().uuidString)", isDirectory: true)
    }

    private func writeFakeMethodRunner(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let script = """
        #!/bin/sh
        exit 0
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

private actor MutationRecorder {
    private var requests: [RuntimeRunMutationRequest] = []

    func append(_ request: RuntimeRunMutationRequest) {
        requests.append(request)
    }

    func allRequests() -> [RuntimeRunMutationRequest] {
        requests
    }
}

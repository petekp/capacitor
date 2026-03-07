@testable import Capacitor
import XCTest

final class ProjectIngestionWorkerTests: XCTestCase {
    func testAddProjectsUsesMutationGatewayAndReturnsMixedOutcome() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let validPath = root.appendingPathComponent("valid", isDirectory: true).path
        let trackedPath = root.appendingPathComponent("tracked", isDirectory: true).path
        let invalidPath = root.appendingPathComponent("invalid", isDirectory: true).path
        let filePath = root.appendingPathComponent("notes.txt").path

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: validPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: trackedPath, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: invalidPath, withIntermediateDirectories: true)
        try Data("scratch".utf8).write(to: URL(fileURLWithPath: filePath))
        defer { try? FileManager.default.removeItem(at: root) }

        let gateway = StubProjectMutationGateway(
            validationResults: [
                validPath: ShellProjectValidationResult(
                    kind: .valid,
                    path: validPath,
                    suggestedPath: nil,
                    reason: nil,
                    hasClaudeMd: true,
                    hasOtherMarkers: true,
                ),
                trackedPath: ShellProjectValidationResult(
                    kind: .alreadyTracked,
                    path: "/canonical/tracked",
                    suggestedPath: nil,
                    reason: nil,
                    hasClaudeMd: true,
                    hasOtherMarkers: true,
                ),
                invalidPath: ShellProjectValidationResult(
                    kind: .notAProject,
                    path: invalidPath,
                    suggestedPath: nil,
                    reason: "No markers",
                    hasClaudeMd: false,
                    hasOtherMarkers: false,
                ),
            ],
        )
        let worker = ProjectIngestionWorker(projectMutationGateway: gateway)

        let outcome = await worker.addProjects(paths: [validPath, trackedPath, invalidPath, filePath])

        XCTAssertEqual(outcome.addedCount, 1)
        XCTAssertEqual(outcome.addedPaths, [validPath])
        XCTAssertEqual(outcome.alreadyTrackedPaths, ["/canonical/tracked"])
        XCTAssertEqual(outcome.failedNames, ["invalid (not a project)"])
        XCTAssertEqual(gateway.validatedPaths, [validPath, trackedPath, invalidPath])
        XCTAssertEqual(gateway.addedPaths, [validPath])
    }

    func testSuggestParentDecisionFlagsFailureWithSuggestedName() {
        let result = ShellProjectValidationResult(
            kind: .suggestParent,
            path: "/tmp/project/subdir",
            suggestedPath: "/tmp/project",
            reason: nil,
            hasClaudeMd: false,
            hasOtherMarkers: true,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/project/subdir", result: result)

        switch decision {
        case let .failed(name):
            XCTAssertEqual(name, "subdir (use project)")
        default:
            XCTFail("Expected failed decision for suggest_parent")
        }
    }

    func testNotAProjectDecisionFlagsFailureWithReason() {
        let result = ShellProjectValidationResult(
            kind: .notAProject,
            path: "/tmp/empty",
            suggestedPath: nil,
            reason: "No markers",
            hasClaudeMd: false,
            hasOtherMarkers: false,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/empty", result: result)

        switch decision {
        case let .failed(name):
            XCTAssertEqual(name, "empty (not a project)")
        default:
            XCTFail("Expected failed decision for not_a_project")
        }
    }

    func testAlreadyTrackedDecisionReturnsTrackedPath() {
        let result = ShellProjectValidationResult(
            kind: .alreadyTracked,
            path: "/tmp/project",
            suggestedPath: nil,
            reason: nil,
            hasClaudeMd: true,
            hasOtherMarkers: true,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/project", result: result)

        switch decision {
        case let .alreadyTracked(path):
            XCTAssertEqual(path, "/tmp/project")
        default:
            XCTFail("Expected alreadyTracked decision")
        }
    }

    func testValidDecisionAddsPath() {
        let result = ShellProjectValidationResult(
            kind: .valid,
            path: "/tmp/project",
            suggestedPath: nil,
            reason: nil,
            hasClaudeMd: true,
            hasOtherMarkers: true,
        )

        let decision = ProjectIngestionWorker.decision(for: "/tmp/project", result: result)

        switch decision {
        case let .add(path):
            XCTAssertEqual(path, "/tmp/project")
        default:
            XCTFail("Expected add decision for valid project")
        }
    }
}

private final class StubProjectMutationGateway: ProjectMutationGateway {
    let validationResults: [String: ShellProjectValidationResult]
    private(set) var validatedPaths: [String] = []
    private(set) var addedPaths: [String] = []

    init(validationResults: [String: ShellProjectValidationResult]) {
        self.validationResults = validationResults
    }

    func addProject(path: String) throws {
        addedPaths.append(path)
    }

    func removeProject(path _: String) throws {}

    func validateProject(path: String) throws -> ShellProjectValidationResult {
        validatedPaths.append(path)
        guard let result = validationResults[path] else {
            throw NSError(domain: "StubProjectMutationGateway", code: 1)
        }
        return result
    }

    func createProjectClaudeMd(projectPath _: String) throws {}
}

@testable import Capacitor
import Foundation
import XCTest

final class WorkBatchHomeProjectionTests: XCTestCase {
    func testGroupsOrderedVisibleProjectsAsHomeSections() {
        let capacitor = project(name: "Capacitor", path: "/tmp/capacitor")
        let parable = project(name: "parable-school", path: "/tmp/parable-school")
        let hidden = project(name: "Hidden", path: "/tmp/hidden")
        let batch = projection(id: "batch-type", name: "Typeface unification")

        let sections = WorkBatchHomeProjection.make(
            projects: [parable, hidden, capacitor],
            projectOrder: [capacitor.path, parable.path, hidden.path],
            hiddenProjectPaths: [hidden.path],
            batchesByProjectPath: [
                parable.path: [batch],
            ],
        )

        XCTAssertEqual(sections.map(\.project.name), ["Capacitor", "parable-school"])
        XCTAssertEqual(sections[0].batches, [])
        XCTAssertEqual(sections[1].batches.map(\.name), ["Typeface unification"])
    }

    func testSectionCountsBatchesAndQueuedTasks() {
        let section = WorkBatchHomeSection(
            project: project(name: "Capacitor", path: "/tmp/capacitor"),
            batches: [
                projection(id: "batch-one", name: "One", queuedTaskCount: 2),
                projection(id: "batch-two", name: "Two", queuedTaskCount: 1),
            ],
        )

        XCTAssertEqual(section.batchCount, 2)
        XCTAssertEqual(section.queuedTaskCount, 3)
    }

    private func project(name: String, path: String) -> Project {
        Project(
            name: name,
            path: path,
            workspaceId: WorkspaceIdentity.fromPath(path),
            displayPath: path,
            lastActive: nil,
            claudeMdPath: nil,
            claudeMdPreview: nil,
            hasLocalSettings: false,
            taskCount: 0,
            stats: nil,
            isMissing: false,
        )
    }

    private func projection(
        id: String,
        name: String,
        queuedTaskCount: Int = 0,
    ) -> WorkBatchProjection {
        WorkBatchProjection(
            id: id,
            name: name,
            status: .ready,
            queuedTaskCount: queuedTaskCount,
            currentActivitySummary: "Ready",
            tasks: [],
            binding: nil,
        )
    }
}

@testable import Capacitor
import Foundation
import XCTest

@MainActor
final class ProjectImportCoordinatorTests: XCTestCase {
    func testConnectViaFileBrowserImportsMultipleSelectionsAndShowsProjectList() async {
        var importedPaths: [String] = []
        var ensuredListVisible = false
        let coordinator = ProjectImportCoordinator(
            selectDirectories: {
                [
                    URL(fileURLWithPath: "/tmp/a"),
                    URL(fileURLWithPath: "/tmp/b"),
                ]
            },
            connectSingleProject: { _ in
                XCTFail("single-project connect should not run")
            },
            importProjects: { urls in
                importedPaths = urls.map(\.path)
            },
            ensureProjectListVisible: {
                ensuredListVisible = true
            },
        )

        coordinator.connectViaFileBrowser()
        await _Concurrency.Task.yield()

        XCTAssertEqual(importedPaths, ["/tmp/a", "/tmp/b"])
        XCTAssertTrue(ensuredListVisible)
    }

    func testCollectDroppedFileURLsIncludesAsyncValidItems() {
        let coordinator = ProjectImportCoordinator(
            connectSingleProject: { _ in },
            importProjects: { _ in },
            ensureProjectListVisible: {},
        )
        let urlA = URL(fileURLWithPath: "/tmp/drop-a")
        let urlB = URL(fileURLWithPath: "/tmp/drop-b")

        let exp = expectation(description: "drop URLs collected")
        coordinator.collectDroppedFileURLsForTesting(
            loaders: [
                { completion in
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.01) {
                        completion(urlA.dataRepresentation)
                    }
                },
                { completion in
                    DispatchQueue.global(qos: .userInitiated).async {
                        completion(nil)
                    }
                },
                { completion in
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.005) {
                        completion(urlB.dataRepresentation)
                    }
                },
            ],
        ) { urls in
            XCTAssertEqual(Set(urls.map(\.path)), Set([urlA.path, urlB.path]))
            exp.fulfill()
        }

        wait(for: [exp], timeout: 1.0)
    }
}

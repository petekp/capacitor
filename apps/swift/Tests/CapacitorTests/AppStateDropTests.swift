@testable import Capacitor
import XCTest

@MainActor
final class AppStateDropTests: XCTestCase {
    func testCollectDroppedFileURLsIncludesAsyncValidItems() {
        let appState = AppState()
        let urlA = URL(fileURLWithPath: "/tmp/drop-a")
        let urlB = URL(fileURLWithPath: "/tmp/drop-b")

        let exp = expectation(description: "drop URLs collected")
        appState.projectImportCoordinator.collectDroppedFileURLsForTesting(
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

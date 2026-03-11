@testable import Capacitor
import XCTest

final class ProjectOrderStoreTests: XCTestCase {
    func testSaveAndLoadGlobalOrder() throws {
        let suiteName = "ProjectOrderStoreTests-global-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        ProjectOrderStore.save(["/tmp/a", "/tmp/b"], to: defaults)
        let loaded = ProjectOrderStore.load(from: defaults)

        XCTAssertEqual(loaded, ["/tmp/a", "/tmp/b"])
    }

    func testLoadReturnsEmptyWithoutGlobalKey() throws {
        let suiteName = "ProjectOrderStoreTests-no-global-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let loaded = ProjectOrderStore.load(from: defaults)

        XCTAssertEqual(loaded, [])
    }

    func testLoadReturnsEmptyArrayByDefault() throws {
        let suiteName = "ProjectOrderStoreTests-empty-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        XCTAssertEqual(ProjectOrderStore.load(from: defaults), [])
    }
}

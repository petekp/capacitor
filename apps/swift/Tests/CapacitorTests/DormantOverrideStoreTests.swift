@testable import Capacitor
import XCTest

final class DormantOverrideStoreTests: XCTestCase {
    func testSaveAndLoadDormantOverrides() throws {
        let suiteName = "DormantOverrideStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        DormantOverrideStore.save(["/tmp/a", "/tmp/b"], to: defaults)
        let loaded = DormantOverrideStore.load(from: defaults)

        XCTAssertEqual(loaded, Set(["/tmp/a", "/tmp/b"]))
    }
}

@testable import Capacitor
import XCTest

final class CapacitorProjectPathsTests: XCTestCase {
    func testProjectDataDirectoryUsesNormalizedProjectPathForStableKeying() {
        let mixedCasePath = "/Users/Pete/Code/Capacitor-\(UUID().uuidString)"
        let normalizedPath = PathNormalizer.normalize(mixedCasePath)

        XCTAssertNotEqual(mixedCasePath, normalizedPath)

        let projectDataDirectory = CapacitorProjectPaths.projectDataDirectory(for: mixedCasePath)

        XCTAssertEqual(
            projectDataDirectory.lastPathComponent,
            CapacitorProjectPaths.encodePath(normalizedPath),
        )
    }
}

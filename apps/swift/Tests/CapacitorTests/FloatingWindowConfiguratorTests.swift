import AppKit
@testable import Capacitor
import XCTest

final class FloatingWindowConfiguratorTests: XCTestCase {
    func testFloatingStyleKeepsWindowKeyableForTextInput() {
        let styleMask = FloatingWindowConfigurator.floatingStyleMask(from: [])

        XCTAssertTrue(styleMask.contains(.titled))
        XCTAssertTrue(styleMask.contains(.fullSizeContentView))
    }
}

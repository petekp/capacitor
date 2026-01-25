@testable import Capacitor
import XCTest

final class WindowCornerRadiusTests: XCTestCase {
    func testFloatingModeUsesPanelCornerRadius() {
        let config = GlassConfig()
        config.panelCornerRadius = 24.5

        let radius = WindowCornerRadius.value(floatingMode: true, config: config)

        XCTAssertEqual(radius, 24.5, accuracy: 0.001)
    }

    func testNonFloatingModeUsesZero() {
        let config = GlassConfig()
        config.panelCornerRadius = 31.0

        let radius = WindowCornerRadius.value(floatingMode: false, config: config)

        XCTAssertEqual(radius, 0, accuracy: 0.001)
    }
}

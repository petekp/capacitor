@testable import Capacitor
import Foundation
import XCTest

final class SupportedTerminalAppTests: XCTestCase {
    func testApplicationURLUsesWorkspaceLookupWhenAppIsNotRunning() {
        let expectedURL = URL(fileURLWithPath: "/Users/pete/Applications/Ghostty.app")

        let resolvedURL = SupportedTerminalApp.ghostty.applicationURL(
            runningApplicationURLsByBundleIdentifier: [:],
            workspaceURLResolver: { bundleIdentifier in
                bundleIdentifier == SupportedTerminalApp.ghostty.bundleId ? expectedURL : nil
            },
            fileExistsAtPath: { _ in
                XCTFail("Filesystem fallback should not run when workspace lookup succeeds")
                return false
            },
        )

        XCTAssertEqual(resolvedURL, expectedURL)
    }

    func testDetectAvailableUsesResolvedInstallationURLWhenNothingIsRunning() {
        let detected = SupportedTerminalApp.detectAvailable(
            runningBundleIdentifiers: [],
            installationURLResolver: { app in
                app == .iTerm ? URL(fileURLWithPath: "/Users/pete/Applications/iTerm.app") : nil
            },
        )

        XCTAssertEqual(detected, .iTerm)
    }
}

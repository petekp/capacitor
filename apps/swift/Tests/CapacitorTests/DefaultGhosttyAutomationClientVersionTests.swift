@testable import Capacitor
import Foundation
import XCTest

final class DefaultGhosttyAutomationClientVersionTests: XCTestCase {
    func testInstalledGhosttyVersionReadsBundleOutsideApplicationsDirectory() throws {
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let bundleURL = tempRoot
            .appendingPathComponent("Ghostty.app", isDirectory: true)

        try FileManager.default.createDirectory(
            at: bundleURL.appendingPathComponent("Contents", isDirectory: true),
            withIntermediateDirectories: true,
        )

        let plistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist")
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": "1.3.7"],
            format: .xml,
            options: 0,
        )
        try plistData.write(to: plistURL)
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let version = DefaultGhosttyAutomationClient.installedGhosttyVersion {
            bundleURL
        }

        XCTAssertEqual(version, "1.3.7")
    }
}

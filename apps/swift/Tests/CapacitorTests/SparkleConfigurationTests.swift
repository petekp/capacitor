import XCTest
import Foundation

struct SparkleConfiguration {
    let feedURL: String?
    let publicKey: String?

    init(bundle: Bundle = .main) {
        self.feedURL = bundle.infoDictionary?["SUFeedURL"] as? String
        self.publicKey = bundle.infoDictionary?["SUPublicEDKey"] as? String
    }

    init(feedURL: String?, publicKey: String?) {
        self.feedURL = feedURL
        self.publicKey = publicKey
    }

    var isValid: Bool {
        guard let feedURL, !feedURL.isEmpty else { return false }
        guard let publicKey, !publicKey.isEmpty else { return false }
        guard publicKey != "YOUR_PUBLIC_KEY_HERE" else { return false }
        return true
    }
}

final class SparkleConfigurationTests: XCTestCase {

    func testValidConfiguration() {
        let config = SparkleConfiguration(
            feedURL: "https://example.com/appcast.xml",
            publicKey: "abc123EdDSAKey=="
        )
        XCTAssertTrue(config.isValid)
    }

    func testMissingFeedURL() {
        let config = SparkleConfiguration(
            feedURL: nil,
            publicKey: "abc123EdDSAKey=="
        )
        XCTAssertFalse(config.isValid)
    }

    func testEmptyFeedURL() {
        let config = SparkleConfiguration(
            feedURL: "",
            publicKey: "abc123EdDSAKey=="
        )
        XCTAssertFalse(config.isValid)
    }

    func testMissingPublicKey() {
        let config = SparkleConfiguration(
            feedURL: "https://example.com/appcast.xml",
            publicKey: nil
        )
        XCTAssertFalse(config.isValid)
    }

    func testEmptyPublicKey() {
        let config = SparkleConfiguration(
            feedURL: "https://example.com/appcast.xml",
            publicKey: ""
        )
        XCTAssertFalse(config.isValid)
    }

    func testPlaceholderPublicKey() {
        let config = SparkleConfiguration(
            feedURL: "https://example.com/appcast.xml",
            publicKey: "YOUR_PUBLIC_KEY_HERE"
        )
        XCTAssertFalse(config.isValid)
    }

    func testBothMissing() {
        let config = SparkleConfiguration(
            feedURL: nil,
            publicKey: nil
        )
        XCTAssertFalse(config.isValid)
    }

    func testBothEmpty() {
        let config = SparkleConfiguration(
            feedURL: "",
            publicKey: ""
        )
        XCTAssertFalse(config.isValid)
    }

    func testRealWorldConfiguration() {
        let config = SparkleConfiguration(
            feedURL: "https://github.com/petekp/claude-hud/releases/latest/download/appcast.xml",
            publicKey: "F9qGHLJ2ro5Q+mffrwkiQSGpkGD5+GCDnusHuRkXqrE="
        )
        XCTAssertTrue(config.isValid)
    }
}

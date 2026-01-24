import Foundation
import os.log

private let logger = Logger(subsystem: "com.capacitor.app", category: "ResourceBundle")

enum ResourceBundle {
    /// The bundle containing app resources (logomark, assets, etc.)
    /// Works in both SPM dev builds and distributed app bundles.
    static let bundle: Bundle? = {
        let bundleName = "Capacitor_Capacitor"

        logger.debug("Looking for resource bundle '\(bundleName)'")
        logger.debug("  Bundle.main.bundlePath: \(Bundle.main.bundlePath)")
        logger.debug("  Bundle.main.resourceURL: \(Bundle.main.resourceURL?.path ?? "nil")")

        // Candidate locations to search, in order of preference:
        let candidates: [(String, URL?)] = [
            ("resourceURL", Bundle.main.resourceURL),
            ("bundleURL", Bundle.main.bundleURL),
            ("executableDir", Bundle.main.executableURL?.deletingLastPathComponent()),
        ]

        for (name, candidate) in candidates {
            guard let candidate = candidate else {
                logger.debug("  Candidate \(name): nil")
                continue
            }

            // Try with .bundle extension
            let bundlePath = candidate.appendingPathComponent(bundleName + ".bundle")
            logger.debug("  Trying: \(bundlePath.path)")
            if let bundle = Bundle(url: bundlePath) {
                logger.info("✅ Found resource bundle at: \(bundlePath.path)")
                return bundle
            }

            // Try in Resources subdirectory
            let resourcePath = candidate
                .appendingPathComponent("Resources")
                .appendingPathComponent(bundleName + ".bundle")
            logger.debug("  Trying: \(resourcePath.path)")
            if let bundle = Bundle(url: resourcePath) {
                logger.info("✅ Found resource bundle at: \(resourcePath.path)")
                return bundle
            }
        }

        logger.warning("⚠️ Resource bundle not found, falling back to Bundle.main")
        return Bundle.main
    }()

    /// Get a resource URL, returning nil if not found (never crashes)
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        let url = bundle?.url(forResource: name, withExtension: ext)
        if url == nil {
            logger.warning("Resource not found: \(name).\(ext) in bundle: \(bundle?.bundlePath ?? "nil")")
        }
        return url
    }
}

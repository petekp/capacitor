import Foundation

enum HookInstaller {
    private static let targetPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/hud-hook").path

    /// Installs the bundled hud-hook binary to ~/.local/bin/hud-hook.
    ///
    /// This is the client-side helper that:
    /// 1. Finds the bundled binary in the app bundle (platform-specific)
    /// 2. Calls the core's install_hook_binary_from_path() for the actual installation
    ///
    /// In development mode (swift run), the binary won't be bundled. If the binary
    /// is already installed at the target location (via sync-hooks.sh), we skip
    /// installation and return success.
    ///
    /// Returns nil on success, or an error message on failure.
    static func installBundledBinary(using engine: CoreRuntime) -> String? {
        if let sourcePath = findBundledBinary() {
            do {
                let result = try engine.installHookBinaryFromPath(sourcePath: sourcePath)
                if result.success {
                    return nil
                } else {
                    return result.message
                }
            } catch {
                return "Failed to install hook binary: \(error.localizedDescription)"
            }
        }

        if isTargetBinaryInstalled() {
            return nil
        }

        return "Hook binary not bundled with this app. Run ./scripts/sync-hooks.sh to install."
    }

    /// Checks if the target binary already exists and is executable.
    /// Used as a fallback in development mode when no bundled binary is available.
    private static func isTargetBinaryInstalled() -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: targetPath) else { return false }
        return fileManager.isExecutableFile(atPath: targetPath)
    }

    /// Finds the bundled hud-hook binary in the app bundle.
    ///
    /// Checks both Bundle.main.url(forResource:) and the Resources directory
    /// directly, to handle both SPM development and distributed app scenarios.
    private static func findBundledBinary() -> String? {
        if let bundledBinary = Bundle.main.url(forResource: "hud-hook", withExtension: nil) {
            return bundledBinary.path
        }

        if let resourcesPath = Bundle.main.resourcePath {
            let resourcesBinary = URL(fileURLWithPath: resourcesPath).appendingPathComponent("hud-hook")
            if FileManager.default.fileExists(atPath: resourcesBinary.path) {
                return resourcesBinary.path
            }
        }

        return nil
    }
}

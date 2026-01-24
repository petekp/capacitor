import Foundation

enum HookInstaller {
    /// Installs the bundled hud-hook binary to ~/.local/bin/hud-hook.
    ///
    /// This is the client-side helper that:
    /// 1. Finds the bundled binary in the app bundle (platform-specific)
    /// 2. Calls the core's install_hook_binary_from_path() for the actual installation
    ///
    /// Returns nil on success, or an error message on failure.
    static func installBundledBinary(using engine: HudEngine) -> String? {
        guard let sourcePath = findBundledBinary() else {
            return "Hook binary not bundled with this app. Please reinstall Claude HUD."
        }

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

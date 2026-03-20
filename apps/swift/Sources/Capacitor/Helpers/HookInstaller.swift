import Foundation

protocol HookRuntimeInstalling {
    func installHookBinaryFromPath(sourcePath: String) throws -> InstallResult
    func installHooks() throws -> InstallResult
    func getHookStatus() -> HookStatus
}

extension CoreRuntime: HookRuntimeInstalling {}

enum HookBinaryLocator {
    /// The canonical runtime binary path used by shell hooks and the Swift app in development.
    /// In normal local development this is a symlink to `target/release/hud-hook`.
    static let canonicalInstallPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/bin/hud-hook").path

    static func isRunningFromAppBundle(bundle: Bundle = .main) -> Bool {
        bundle.bundleURL.pathExtension == "app"
    }

    static func bundledBinaryPath(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
    ) -> String? {
        if let bundledBinary = bundle.url(forResource: "hud-hook", withExtension: nil),
           fileManager.isExecutableFile(atPath: bundledBinary.path)
        {
            return bundledBinary.path
        }

        if let resourcesPath = bundle.resourcePath {
            let resourcesBinary = URL(fileURLWithPath: resourcesPath).appendingPathComponent("hud-hook")
            if fileManager.isExecutableFile(atPath: resourcesBinary.path) {
                return resourcesBinary.path
            }
        }

        return nil
    }

    static func preferredLaunchBinaryPath(
        isRunningFromAppBundle: Bool = HookBinaryLocator.isRunningFromAppBundle(),
        installedBinaryPath: String = HookBinaryLocator.canonicalInstallPath,
        bundledBinaryPath: String? = HookBinaryLocator.bundledBinaryPath(),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    ) -> String {
        if isRunningFromAppBundle,
           let bundledBinaryPath,
           isExecutableFile(bundledBinaryPath)
        {
            return bundledBinaryPath
        }

        return installedBinaryPath
    }

    static func installSourceBinaryPath(
        isRunningFromAppBundle: Bool = HookBinaryLocator.isRunningFromAppBundle(),
        installedBinaryPath: String = HookBinaryLocator.canonicalInstallPath,
        bundledBinaryPath: String? = HookBinaryLocator.bundledBinaryPath(),
        isExecutableFile: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
    ) -> String? {
        if isRunningFromAppBundle,
           let bundledBinaryPath,
           isExecutableFile(bundledBinaryPath)
        {
            return bundledBinaryPath
        }

        guard !isExecutableFile(installedBinaryPath) else {
            return nil
        }

        return nil
    }
}

enum HookInstaller {
    typealias BinaryInstallStep = (_ engine: any HookRuntimeInstalling) -> String?

    /// Installs and configures hooks using one canonical flow.
    ///
    /// Returns nil on success or a user-facing error string on failure.
    static func ensureHooksInstalled(
        using engine: any HookRuntimeInstalling,
        binaryInstallStep: BinaryInstallStep = { installRuntimeBinaryIfNeeded(using: $0) },
    ) -> String? {
        if let installError = binaryInstallStep(engine) {
            return installError
        }

        do {
            let result = try engine.installHooks()
            if !result.success {
                return result.message
            }
        } catch {
            return "Installation failed: \(error.localizedDescription)"
        }

        let status = engine.getHookStatus()
        if case .installed = status {
            return nil
        }

        return "Hook install completed but status is \(String(describing: status))"
    }

    /// Installs the bundled hud-hook binary to ~/.local/bin/hud-hook.
    ///
    /// `~/.local/bin/hud-hook` is the single canonical runtime path. In development
    /// that path is usually a symlink to `target/release/hud-hook`, so we avoid
    /// reseeding it from a staged bundle copy. Distributed app bundles may ship a
    /// `hud-hook` resource, and in that case we install that resource into the
    /// canonical path.
    ///
    /// Returns nil on success, or an error message on failure.
    static func installRuntimeBinaryIfNeeded(using engine: any HookRuntimeInstalling) -> String? {
        if let sourcePath = HookBinaryLocator.installSourceBinaryPath() {
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

        return "Hook binary not installed at \(HookBinaryLocator.canonicalInstallPath). Run ./scripts/sync-hooks.sh to create the canonical symlink."
    }

    /// Checks if the target binary already exists and is executable.
    private static func isTargetBinaryInstalled() -> Bool {
        let fileManager = FileManager.default
        return fileManager.isExecutableFile(atPath: HookBinaryLocator.canonicalInstallPath)
    }
}

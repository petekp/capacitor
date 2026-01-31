import Darwin
import Foundation

enum DaemonService {
    private enum Constants {
        static let label = "com.capacitor.daemon"
        static let binaryName = "capacitor-daemon"
        static let enabledEnv = "CAPACITOR_DAEMON_ENABLED"
        static let throttleInterval: Int = 10
    }

    static func ensureRunning() -> String? {
        setenv(Constants.enabledEnv, "1", 1)

        if let installError = DaemonInstaller.installBundledBinary() {
            return installError
        }

        let binaryPath = DaemonInstaller.targetPath
        return LaunchAgentManager.installAndKickstart(binaryPath: binaryPath)
    }

    private enum DaemonInstaller {
        static let targetPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/\(Constants.binaryName)")
            .path

        static func installBundledBinary() -> String? {
            if let sourcePath = findBundledBinary() {
                return symlinkBinary(from: sourcePath, to: targetPath)
            }

            if isTargetBinaryInstalled() {
                return nil
            }

            return "Daemon binary not bundled with this app. Build capacitor-daemon or reinstall the app."
        }

        private static func isTargetBinaryInstalled() -> Bool {
            let fileManager = FileManager.default
            guard fileManager.fileExists(atPath: targetPath) else { return false }
            return fileManager.isExecutableFile(atPath: targetPath)
        }

        private static func findBundledBinary() -> String? {
            if let bundledBinary = Bundle.main.url(forResource: Constants.binaryName, withExtension: nil) {
                return bundledBinary.path
            }

            if let resourcesPath = Bundle.main.resourcePath {
                let resourcesBinary = URL(fileURLWithPath: resourcesPath).appendingPathComponent(Constants.binaryName)
                if FileManager.default.fileExists(atPath: resourcesBinary.path) {
                    return resourcesBinary.path
                }
            }

            if let executableURL = Bundle.main.executableURL {
                let siblingBinary = executableURL.deletingLastPathComponent().appendingPathComponent(Constants.binaryName)
                if FileManager.default.fileExists(atPath: siblingBinary.path) {
                    return siblingBinary.path
                }
            }

            return nil
        }

        private static func symlinkBinary(from sourcePath: String, to destinationPath: String) -> String? {
            let fileManager = FileManager.default
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let destURL = URL(fileURLWithPath: destinationPath)
            let destDir = destURL.deletingLastPathComponent()

            do {
                try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true, attributes: nil)

                if fileManager.fileExists(atPath: destURL.path) {
                    try fileManager.removeItem(at: destURL)
                }

                try fileManager.createSymbolicLink(at: destURL, withDestinationURL: sourceURL)
                return nil
            } catch {
                return "Failed to install daemon binary: \(error.localizedDescription)"
            }
        }
    }

    private enum LaunchAgentManager {
        static func installAndKickstart(binaryPath: String) -> String? {
            let plistURL: URL
            let didUpdate: Bool
            do {
                (plistURL, didUpdate) = try writeLaunchAgentPlist(binaryPath: binaryPath)
            } catch {
                return "Failed to write LaunchAgent plist: \(error.localizedDescription)"
            }

            let domain = "gui/\(getuid())"

            let status = launchctlStatus(domain: domain, label: Constants.label)

            if status == nil || didUpdate {
                _ = runLaunchctl(["bootout", domain, plistURL.path])
                let bootstrap = runLaunchctl(["bootstrap", domain, plistURL.path])
                if bootstrap.exitCode != 0 {
                    return "Failed to bootstrap daemon: \(bootstrap.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                }
            }

            if status?.isRunning == true && !didUpdate {
                return nil
            }

            let kickstart = runLaunchctl(["kickstart", "\(domain)/\(Constants.label)"])
            if kickstart.exitCode != 0 {
                return "Failed to start daemon: \(kickstart.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            }

            return nil
        }

        private struct LaunchctlStatus {
            let isRunning: Bool
        }

        private static func launchctlStatus(domain: String, label: String) -> LaunchctlStatus? {
            let result = runLaunchctl(["print", "\(domain)/\(label)"])
            if result.exitCode != 0 {
                return nil
            }
            let isRunning = result.output.contains("state = running")
            return LaunchctlStatus(isRunning: isRunning)
        }

        private static func writeLaunchAgentPlist(binaryPath: String) throws -> (URL, Bool) {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
            let logsDir = home.appendingPathComponent(".capacitor/daemon")

            try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
            try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true, attributes: nil)

            let plist: [String: Any] = [
                "Label": Constants.label,
                "ProgramArguments": [binaryPath],
                "RunAtLoad": true,
                "KeepAlive": true,
                "ThrottleInterval": Constants.throttleInterval,
                "ProcessType": "Background",
                "WorkingDirectory": home.appendingPathComponent(".capacitor").path,
                "StandardOutPath": logsDir.appendingPathComponent("daemon.stdout.log").path,
                "StandardErrorPath": logsDir.appendingPathComponent("daemon.stderr.log").path
            ]

            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            let plistURL = launchAgentsDir.appendingPathComponent("\(Constants.label).plist")
            if let existing = try? Data(contentsOf: plistURL), existing == data {
                return (plistURL, false)
            }

            try data.write(to: plistURL, options: .atomic)
            return (plistURL, true)
        }

        private static func runLaunchctl(_ arguments: [String]) -> (exitCode: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = arguments

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                return (1, error.localizedDescription)
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return (process.terminationStatus, output)
        }
    }
}

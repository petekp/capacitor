import AppKit
import Foundation

struct DevEnvironment {
    static let devServerPorts: [UInt16] = [3000, 5173, 8080, 4200, 3001, 8000, 4000]
    static let supportedBrowsers = ["Arc", "Google Chrome", "Safari"]

    struct DevServerInfo {
        let port: UInt16
        let browser: String?
    }

    static func findDevServerPort(for projectPath: String) async -> UInt16? {
        let expectedPort = getExpectedPort(for: projectPath)

        if let port = expectedPort {
            if await isPortResponding(port: port) {
                return port
            }
        }

        for port in devServerPorts {
            if port == expectedPort { continue }
            if await isPortResponding(port: port) {
                return port
            }
        }
        return nil
    }

    private static func getExpectedPort(for projectPath: String) -> UInt16? {
        let packageJsonPath = (projectPath as NSString).appendingPathComponent("package.json")

        guard FileManager.default.fileExists(atPath: packageJsonPath),
              let data = FileManager.default.contents(atPath: packageJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else {
            return nil
        }

        let devScript = scripts["dev"] ?? scripts["start"] ?? ""

        if devScript.contains("--port") {
            let pattern = #"--port[=\s]+(\d+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: devScript, range: NSRange(devScript.startIndex..., in: devScript)),
               let portRange = Range(match.range(at: 1), in: devScript) {
                return UInt16(devScript[portRange])
            }
        }

        if devScript.contains("-p") {
            let pattern = #"-p[=\s]+(\d+)"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: devScript, range: NSRange(devScript.startIndex..., in: devScript)),
               let portRange = Range(match.range(at: 1), in: devScript) {
                return UInt16(devScript[portRange])
            }
        }

        if devScript.contains("vite") || devScript.contains("5173") {
            return 5173
        }
        if devScript.contains("next") || devScript.contains("3000") {
            return 3000
        }
        if devScript.contains("angular") || devScript.contains("4200") {
            return 4200
        }

        return nil
    }

    private static func isPortResponding(port: UInt16) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }

        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 0.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                return (200...599).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            return false
        }
    }

    static func findBrowserWithLocalhost(port: UInt16) async -> String? {
        for browser in supportedBrowsers {
            if await browserHasTab(browser: browser, port: port) {
                return browser
            }
        }
        return nil
    }

    private static func browserHasTab(browser: String, port: UInt16) async -> Bool {
        let script: String

        switch browser {
        case "Safari":
            script = """
                tell application "System Events"
                    if exists process "Safari" then
                        tell application "Safari"
                            set allURLs to ""
                            repeat with w in windows
                                repeat with t in tabs of w
                                    set allURLs to allURLs & URL of t & "\\n"
                                end repeat
                            end repeat
                            return allURLs
                        end tell
                    end if
                end tell
            """
        case "Arc":
            script = """
                tell application "System Events"
                    if exists process "Arc" then
                        tell application "Arc"
                            set allURLs to ""
                            repeat with w in windows
                                repeat with t in tabs of w
                                    set allURLs to allURLs & URL of t & "\\n"
                                end repeat
                            end repeat
                            return allURLs
                        end tell
                    end if
                end tell
            """
        default:
            script = """
                tell application "System Events"
                    if exists process "\(browser)" then
                        tell application "\(browser)"
                            set allURLs to ""
                            repeat with w in windows
                                repeat with t in tabs of w
                                    set allURLs to allURLs & URL of t & "\\n"
                                end repeat
                            end repeat
                            return allURLs
                        end tell
                    end if
                end tell
            """
        }

        guard let output = runAppleScript(script) else { return false }
        return output.contains("localhost:\(port)") || output.contains("127.0.0.1:\(port)")
    }

    static func focusBrowserTab(browser: String, port: UInt16) {
        let script: String

        switch browser {
        case "Safari":
            script = """
                tell application "Safari"
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            if URL of t contains "localhost:\(port)" or URL of t contains "127.0.0.1:\(port)" then
                                set current tab of w to t
                                set index of w to 1
                                activate
                                return
                            end if
                            set tabIndex to tabIndex + 1
                        end repeat
                    end repeat
                end tell
            """
        case "Arc":
            script = """
                tell application "Arc"
                    repeat with w in windows
                        repeat with t in tabs of w
                            if URL of t contains "localhost:\(port)" or URL of t contains "127.0.0.1:\(port)" then
                                tell w to set active tab index to index of t
                                set index of w to 1
                                activate
                                return
                            end if
                        end repeat
                    end repeat
                end tell
            """
        default:
            script = """
                tell application "\(browser)"
                    repeat with w in windows
                        set tabIndex to 1
                        repeat with t in tabs of w
                            if URL of t contains "localhost:\(port)" or URL of t contains "127.0.0.1:\(port)" then
                                set active tab index of w to tabIndex
                                set index of w to 1
                                activate
                                return
                            end if
                            set tabIndex to tabIndex + 1
                        end repeat
                    end repeat
                end tell
            """
        }

        _ = runAppleScript(script)
    }

    static func openInBrowser(port: UInt16) {
        let url = URL(string: "http://localhost:\(port)")!
        NSWorkspace.shared.open(url)
    }

    private static func runAppleScript(_ script: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}

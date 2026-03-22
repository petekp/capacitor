import AppKit
import Foundation

/// Captures web screenshots via the `agent-browser` headless Chrome CLI.
///
/// All web content capture (localhost dev servers, Mermaid diagrams) goes through
/// this service. No macOS permissions required — agent-browser manages its own
/// Chrome for Testing instance.
actor WebCaptureService {
    struct CaptureResult {
        let imagePath: String
        let width: Int?
        let height: Int?
    }

    enum CaptureError: Error, LocalizedError {
        case agentBrowserNotFound
        case navigationFailed(url: String, stderr: String)
        case screenshotFailed(stderr: String)
        case timeout
        case outputFileMissing(path: String)

        var errorDescription: String? {
            switch self {
            case .agentBrowserNotFound:
                "agent-browser is not installed or not in PATH"
            case let .navigationFailed(url, stderr):
                "Failed to navigate to \(url): \(stderr.prefix(200))"
            case let .screenshotFailed(stderr):
                "Screenshot failed: \(stderr.prefix(200))"
            case .timeout:
                "Capture timed out"
            case let .outputFileMissing(path):
                "Screenshot file not created: \(path)"
            }
        }
    }

    private let sessionName = "capacitor-capture"

    /// Capture a screenshot of a URL via agent-browser.
    func captureURL(
        _ url: String,
        outputPath: String,
        timeoutSeconds: Int = 30,
        fullPage: Bool = false,
    ) async throws -> CaptureResult {
        let binary = try findAgentBrowser()

        // Ensure output directory exists
        let outputDir = (outputPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true,
        )

        // Navigate to URL
        let navResult = try await shellExec(
            command: binary,
            arguments: ["open", url, "--session", sessionName],
            timeoutSeconds: timeoutSeconds,
        )

        guard navResult.exitCode == 0 else {
            throw CaptureError.navigationFailed(url: url, stderr: navResult.stderr)
        }

        // Wait for page to render
        let _ = try await shellExec(
            command: binary,
            arguments: ["wait", "2000", "--session", sessionName],
            timeoutSeconds: timeoutSeconds,
        )

        // Take screenshot
        var screenshotArgs = ["screenshot", outputPath, "--session", sessionName]
        if fullPage {
            screenshotArgs.insert("--full", at: 2)
        }

        let shotResult = try await shellExec(
            command: binary,
            arguments: screenshotArgs,
            timeoutSeconds: timeoutSeconds,
        )

        guard shotResult.exitCode == 0 else {
            throw CaptureError.screenshotFailed(stderr: shotResult.stderr)
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw CaptureError.outputFileMissing(path: outputPath)
        }

        // Read image dimensions if possible
        let dimensions = imageDimensions(atPath: outputPath)

        return CaptureResult(
            imagePath: outputPath,
            width: dimensions?.width,
            height: dimensions?.height,
        )
    }

    /// Render Mermaid source to PNG via agent-browser.
    ///
    /// Constructs a data:text/html URL containing mermaid.js CDN + the diagram source,
    /// navigates agent-browser to it, waits for rendering, and captures a screenshot.
    func captureMermaid(
        source: String,
        outputPath: String,
        timeoutSeconds: Int = 30,
    ) async throws -> CaptureResult {
        let binary = try findAgentBrowser()

        // Ensure output directory exists
        let outputDir = (outputPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: outputDir,
            withIntermediateDirectories: true,
        )

        // Build a minimal HTML page with mermaid.js
        let html = mermaidHTML(source: source)

        // Write HTML to a temp file (data URLs can be too long for CLI args)
        let tempHTML = NSTemporaryDirectory() + "cap-mermaid-\(UUID().uuidString).html"
        try html.write(toFile: tempHTML, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempHTML) }

        // Navigate to the temp file
        let navResult = try await shellExec(
            command: binary,
            arguments: ["open", "file://\(tempHTML)", "--session", sessionName],
            timeoutSeconds: timeoutSeconds,
        )

        guard navResult.exitCode == 0 else {
            throw CaptureError.navigationFailed(url: "mermaid-render", stderr: navResult.stderr)
        }

        // Wait for mermaid.js to render
        let _ = try await shellExec(
            command: binary,
            arguments: ["wait", "3000", "--session", sessionName],
            timeoutSeconds: timeoutSeconds,
        )

        // Screenshot
        let shotResult = try await shellExec(
            command: binary,
            arguments: ["screenshot", outputPath, "--session", sessionName],
            timeoutSeconds: timeoutSeconds,
        )

        guard shotResult.exitCode == 0 else {
            throw CaptureError.screenshotFailed(stderr: shotResult.stderr)
        }

        guard FileManager.default.fileExists(atPath: outputPath) else {
            throw CaptureError.outputFileMissing(path: outputPath)
        }

        let dimensions = imageDimensions(atPath: outputPath)

        return CaptureResult(
            imagePath: outputPath,
            width: dimensions?.width,
            height: dimensions?.height,
        )
    }

    /// Check if agent-browser is installed and reachable.
    func isAvailable() -> Bool {
        findAgentBrowserPath() != nil
    }

    /// Close the capture browser session to free resources.
    func closeBrowser() async {
        guard let binary = findAgentBrowserPath() else { return }
        _ = try? await shellExec(
            command: binary,
            arguments: ["close", "--session", sessionName],
            timeoutSeconds: 5,
        )
    }

    // MARK: - Private

    private func findAgentBrowser() throws -> String {
        guard let path = findAgentBrowserPath() else {
            throw CaptureError.agentBrowserNotFound
        }
        return path
    }

    private func findAgentBrowserPath() -> String? {
        // Check known locations
        let candidates = [
            // pnpm global bin (common install location)
            NSHomeDirectory() + "/Library/pnpm/agent-browser",
            // Homebrew
            "/opt/homebrew/bin/agent-browser",
            // Standard paths
            "/usr/local/bin/agent-browser",
            NSHomeDirectory() + "/.local/bin/agent-browser",
        ]

        if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return found
        }

        // Fall back to `which`
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["agent-browser"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    private func mermaidHTML(source: String) -> String {
        let escaped = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")

        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="utf-8">
            <style>
                body {
                    margin: 0;
                    padding: 24px;
                    background: #1a1a2e;
                    display: flex;
                    justify-content: center;
                    align-items: center;
                    min-height: 100vh;
                }
                .mermaid {
                    font-family: -apple-system, BlinkMacSystemFont, sans-serif;
                }
                .mermaid svg {
                    max-width: 100%;
                    height: auto;
                }
            </style>
            <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        </head>
        <body>
            <pre class="mermaid">
        \(escaped)
            </pre>
            <script>
                mermaid.initialize({
                    startOnLoad: true,
                    theme: 'dark',
                    themeVariables: {
                        darkMode: true,
                        background: '#1a1a2e',
                        primaryColor: '#3b82f6',
                        primaryTextColor: '#e5e7eb',
                        primaryBorderColor: '#4b5563',
                        lineColor: '#6b7280',
                        secondaryColor: '#1e3a5f',
                        tertiaryColor: '#1f2937'
                    },
                    flowchart: { curve: 'basis' },
                    fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif',
                    fontSize: 14
                });
            </script>
        </body>
        </html>
        """
    }

    private func imageDimensions(atPath path: String) -> (width: Int, height: Int)? {
        guard let image = NSImage(contentsOfFile: path),
              let rep = image.representations.first
        else { return nil }
        return (width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    // MARK: - Shell Helpers

    private struct ShellResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func shellExec(
        command: String,
        arguments: [String],
        timeoutSeconds: Int,
    ) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: command)
            process.arguments = arguments
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Set up timeout
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + .seconds(timeoutSeconds),
                execute: timeoutItem,
            )

            do {
                try process.run()
                process.waitUntilExit()
                timeoutItem.cancel()

                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: CaptureError.timeout)
                    return
                }

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let result = ShellResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus,
                )
                continuation.resume(returning: result)
            } catch {
                timeoutItem.cancel()
                continuation.resume(throwing: error)
            }
        }
    }
}

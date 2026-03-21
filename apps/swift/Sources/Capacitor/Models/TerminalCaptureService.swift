import Foundation

/// Captures terminal pane content via `tmux capture-pane` and optionally renders
/// to a PNG image using the Freeze CLI tool.
///
/// This service requires NO screen recording permission — it reads from tmux's
/// internal buffer rather than capturing pixels from the screen.
actor TerminalCaptureService {
    struct CapturedTerminal {
        let imagePath: String?
        let textPath: String
        let textContent: String
        let lineCount: Int
    }

    enum CaptureError: Error, LocalizedError {
        case tmuxNotFound
        case paneNotFound(target: String)
        case emptyCapture
        case writeFailed(path: String, underlying: Error)
        case freezeFailed(exitCode: Int32)

        var errorDescription: String? {
            switch self {
            case .tmuxNotFound: "tmux is not installed or not in PATH"
            case let .paneNotFound(target): "tmux pane not found: \(target)"
            case .emptyCapture: "tmux capture-pane returned empty content"
            case let .writeFailed(path, error): "Failed to write capture to \(path): \(error)"
            case let .freezeFailed(code): "Freeze exited with code \(code)"
            }
        }
    }

    /// Capture the text content of a tmux pane.
    ///
    /// - Parameters:
    ///   - sessionName: The tmux session name (e.g., "agent-1")
    ///   - paneTarget: Optional pane target (e.g., "0.0"). If nil, captures the active pane.
    ///   - outputDirectory: Directory to write capture files into.
    ///   - filePrefix: Prefix for output filenames (e.g., "terminal-001").
    /// - Returns: A `CapturedTerminal` with paths and content.
    func capture(
        sessionName: String,
        paneTarget: String? = nil,
        outputDirectory: String,
        filePrefix: String = "terminal",
    ) async throws -> CapturedTerminal {
        let target = paneTarget.map { "\(sessionName):\($0)" } ?? sessionName

        // 1. Capture pane text with ANSI escape codes
        let textContent = try await capturePaneText(target: target)

        guard !textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.emptyCapture
        }

        // 2. Ensure output directory exists
        try FileManager.default.createDirectory(
            atPath: outputDirectory,
            withIntermediateDirectories: true,
        )

        // 3. Write text content
        let textPath = (outputDirectory as NSString).appendingPathComponent("\(filePrefix).txt")
        do {
            try textContent.write(toFile: textPath, atomically: true, encoding: .utf8)
        } catch {
            throw CaptureError.writeFailed(path: textPath, underlying: error)
        }

        // 4. Try to render with Freeze (optional dependency)
        let imagePath = try? await renderWithFreeze(
            textContent: textContent,
            outputDirectory: outputDirectory,
            filePrefix: filePrefix,
        )

        let lineCount = textContent.components(separatedBy: "\n").count

        return CapturedTerminal(
            imagePath: imagePath,
            textPath: textPath,
            textContent: textContent,
            lineCount: lineCount,
        )
    }

    /// Check if tmux is available.
    func isTmuxAvailable() -> Bool {
        shellWhich("tmux") != nil
    }

    /// Check if Freeze CLI is available.
    func isFreezeAvailable() -> Bool {
        shellWhich("freeze") != nil
    }

    // MARK: - Private

    private func capturePaneText(target: String) async throws -> String {
        let result = try await shellExec(
            command: "tmux",
            arguments: ["capture-pane", "-t", target, "-p", "-e"],
        )

        guard result.exitCode == 0 else {
            let stderr = result.stderr.lowercased()
            if stderr.contains("can't find") || stderr.contains("no such")
                || stderr.contains("not found")
            {
                throw CaptureError.paneNotFound(target: target)
            }
            if stderr.contains("no server running") || stderr.contains("no current client") {
                throw CaptureError.tmuxNotFound
            }
            throw CaptureError.paneNotFound(target: "\(target) (tmux exit \(result.exitCode): \(result.stderr.prefix(100)))")
        }

        return result.stdout
    }

    private func renderWithFreeze(
        textContent: String,
        outputDirectory: String,
        filePrefix: String,
    ) async throws -> String {
        let imagePath = (outputDirectory as NSString).appendingPathComponent("\(filePrefix).png")

        // Write text to a temp file for Freeze input
        let tempInput = NSTemporaryDirectory() + "cap-freeze-input-\(UUID().uuidString).txt"
        // Strip ANSI escape codes for Freeze (it handles its own theming)
        let cleanText = textContent.replacingOccurrences(
            of: "\u{1B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression,
        )
        try cleanText.write(toFile: tempInput, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tempInput) }

        let result = try await shellExec(
            command: "freeze",
            arguments: [
                tempInput,
                "--output", imagePath,
                "--theme", "dracula",
                "--font.family", "JetBrains Mono,Menlo,monospace",
                "--font.size", "13",
                "--padding", "20",
                "--margin", "0",
                "--border.radius", "8",
                "--window", "false",
            ],
        )

        guard result.exitCode == 0 else {
            throw CaptureError.freezeFailed(exitCode: result.exitCode)
        }

        return imagePath
    }

    // MARK: - Shell Helpers

    private struct ShellResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func shellExec(command: String, arguments: [String]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            // Find the executable — prefer direct path, fall back to /usr/bin/env
            if let path = shellWhich(command) {
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = arguments
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [command] + arguments
            }

            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            do {
                try process.run()
                process.waitUntilExit()

                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                let result = ShellResult(
                    stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                    stderr: String(data: stderrData, encoding: .utf8) ?? "",
                    exitCode: process.terminationStatus,
                )
                continuation.resume(returning: result)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func shellWhich(_ command: String) -> String? {
        let paths = [
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
            "/usr/bin/\(command)",
        ]
        return paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

import AppKit
import SwiftUI

struct ShellInstructionsSheet: View {
    @Binding var isPresented: Bool
    @State private var copied = false
    @State private var installState: InstallState = .idle
    var onDismiss: () -> Void

    private let shellType = ShellType.current

    private enum InstallState: Equatable {
        case idle
        case installing
        case success
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            configFileSection

            snippetSection

            transparencySection

            instructionsSection

            buttonSection
        }
        .padding(24)
        .frame(width: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.secondary)

                Text("Shell Integration")
                    .font(.title2.weight(.semibold))
            }

            Text("Track your active project as you navigate between directories.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var configFileSection: some View {
        HStack {
            Text("Add to")
                .foregroundStyle(.secondary)

            Text(shellType.configFile)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.primary)

            Spacer()

            Text(shellType.displayName)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.accentColor.opacity(0.2), in: Capsule())
        }
    }

    private var snippetSection: some View {
        ScrollView {
            Text(shellType.snippet)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(height: 140)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var transparencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What this snippet does")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 4) {
                bulletRow("Runs capacitor-hook cwd after each prompt to report your current directory, PID, and TTY.")
                bulletRow("Sends that metadata to the local runtime so Capacitor can map activity to projects.")
                bulletRow("Does not change your prompt text. Remove it any time from \(shellType.configFile).")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var instructionsSection: some View {
        switch installState {
        case .success:
            VStack(alignment: .leading, spacing: 8) {
                Label("Snippet added to \(shellType.configFile)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Restart your terminal or run: source \(shellType.configFile)")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

        case let .error(message):
            VStack(alignment: .leading, spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("You can still copy the snippet manually.")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

        default:
            VStack(alignment: .leading, spacing: 8) {
                instructionRow(number: 1, text: "Copy the snippet above")
                instructionRow(number: 2, text: "Open \(shellType.configFile) in your editor")
                instructionRow(number: 3, text: "Paste at the end of the file and save")
                instructionRow(number: 4, text: "Restart your terminal or run: source \(shellType.configFile)")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func instructionRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(number).")
                .frame(width: 16, alignment: .trailing)
            Text(text)
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .padding(.top, 6)
            Text(text)
        }
    }

    private var buttonSection: some View {
        HStack {
            if installState == .success {
                Button {
                    copyToClipboard()
                } label: {
                    Label(copied ? "Copied!" : "Copy Snippet", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            } else {
                Button {
                    autoInstall()
                } label: {
                    if installState == .installing {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 16, height: 16)
                        Text("Installing...")
                    } else {
                        Label("Add to \(shellType.configFile)", systemImage: "plus.circle")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(installState == .installing)

                Button {
                    copyToClipboard()
                } label: {
                    Label(copied ? "Copied!" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            Button("Done") {
                isPresented = false
                onDismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func autoInstall() {
        installState = .installing

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let result = shellType.installSnippet()
            switch result {
            case .success:
                installState = .success
            case let .failure(error):
                if case .alreadyInstalled = error {
                    installState = .success
                } else {
                    installState = .error(error.localizedDescription)
                }
            }
        }
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(shellType.snippet, forType: .string)
        copied = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            copied = false
        }
    }
}

#Preview {
    ShellInstructionsSheet(isPresented: .constant(true), onDismiss: {})
        .preferredColorScheme(.dark)
}

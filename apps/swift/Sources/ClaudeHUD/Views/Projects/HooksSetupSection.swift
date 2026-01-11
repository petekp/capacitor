import SwiftUI

struct HooksSetupSection: View {
    @StateObject private var hooksManager = HooksManager()
    @State private var showingSetupSheet = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionLabel(title: "HUD HOOKS STATUS")

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    Text(hooksManager.setupStatus.rawValue)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.8))

                    Spacer()

                    if hooksManager.setupStatus != .complete {
                        Button(action: { showingSetupSheet = true }) {
                            Text("Setup")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Text(hooksManager.setupStatus.description)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))

                if hooksManager.setupStatus != .complete {
                    VStack(alignment: .leading, spacing: 6) {
                        HookStatusRow(name: "UserPromptSubmit", enabled: hooksManager.hasUserPromptSubmit, description: "Tracks when you start working")
                        HookStatusRow(name: "PostToolUse", enabled: hooksManager.hasPostToolUse, description: "Heartbeat during activity")
                        HookStatusRow(name: "Stop", enabled: hooksManager.hasStop, description: "Detects ready state")
                        HookStatusRow(name: "Notification", enabled: hooksManager.hasNotification, description: "Idle prompt detection")
                    }
                    .padding(.top, 4)
                }
            }
            .padding(10)
            .background(Color.white.opacity(0.03))
            .cornerRadius(8)
        }
        .onAppear {
            hooksManager.checkSetup()
        }
        .sheet(isPresented: $showingSetupSheet) {
            HooksSetupSheet(hooksManager: hooksManager)
        }
    }

    private var statusColor: Color {
        switch hooksManager.setupStatus {
        case .none: return .red.opacity(0.8)
        case .basic: return .yellow.opacity(0.8)
        case .complete: return .green.opacity(0.8)
        case .custom: return .blue.opacity(0.8)
        }
    }
}

struct HookStatusRow: View {
    let name: String
    let enabled: Bool
    let description: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: enabled ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 10))
                .foregroundColor(enabled ? .green : .white.opacity(0.3))

            Text(name)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))

            Text("- \(description)")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
    }
}

struct HooksSetupSheet: View {
    @ObservedObject var hooksManager: HooksManager
    @Environment(\.dismiss) private var dismiss
    @State private var copiedConfig = false
    @State private var showDiff = false
    @State private var diffLines: [DiffLine] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("HUD Hooks Setup")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Text("To enable real-time state tracking, add these hooks to your ~/.claude/settings.json:")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        showDiff = false
                    }
                } label: {
                    Text("Config")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(!showDiff ? Color.accentColor.opacity(0.2) : Color.clear)
                        .foregroundColor(!showDiff ? .accentColor : .white.opacity(0.5))
                        .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Button {
                    if diffLines.isEmpty {
                        let current = hooksManager.getCurrentSettings()
                        diffLines = HooksManager.generateDiff(current: current, recommended: HooksManager.recommendedHooksConfig)
                    }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        showDiff = true
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 9))
                        Text("Diff Preview")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(showDiff ? Color.accentColor.opacity(0.2) : Color.clear)
                    .foregroundColor(showDiff ? .accentColor : .white.opacity(0.5))
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)

                Spacer()
            }

            ScrollView {
                if showDiff {
                    DiffView(diffLines: diffLines)
                } else {
                    Text(HooksManager.recommendedHooksConfig)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.7))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.3))
                        .cornerRadius(6)
                }
            }
            .frame(maxHeight: 200)

            HStack {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(HooksManager.recommendedHooksConfig, forType: .string)
                    copiedConfig = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedConfig = false
                    }
                }) {
                    HStack {
                        Image(systemName: copiedConfig ? "checkmark" : "doc.on.doc")
                        Text(copiedConfig ? "Copied!" : "Copy Configuration")
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Done") {
                    hooksManager.checkSetup()
                    dismiss()
                }
            }

            Text("After adding the hooks, restart any active Claude sessions for them to take effect.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(20)
        .frame(width: 400)
    }
}

struct DiffView: View {
    let diffLines: [DiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(diffLines) { line in
                HStack(spacing: 0) {
                    Text(linePrefix(for: line.type))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(lineColor(for: line.type))
                        .frame(width: 14, alignment: .center)

                    Text(line.text)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(lineColor(for: line.type))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 1)
                .padding(.horizontal, 4)
                .background(lineBackground(for: line.type))
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.3))
        .cornerRadius(6)
    }

    private func linePrefix(for type: DiffLine.DiffType) -> String {
        switch type {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func lineColor(for type: DiffLine.DiffType) -> Color {
        switch type {
        case .added: return .green.opacity(0.9)
        case .removed: return .red.opacity(0.7)
        case .context: return .white.opacity(0.5)
        }
    }

    private func lineBackground(for type: DiffLine.DiffType) -> Color {
        switch type {
        case .added: return .green.opacity(0.1)
        case .removed: return .red.opacity(0.1)
        case .context: return .clear
        }
    }
}

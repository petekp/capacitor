import SwiftUI

struct ActivityPanel: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    private var visibleRunCompletions: [RuntimeRunState] {
        appState.isMethodRunnerEnabled ? appState.recentTerminalRuns : []
    }

    private var hasActivity: Bool {
        !visibleCreations.isEmpty || !visibleRunCompletions.isEmpty
    }

    private var activityCount: Int {
        visibleCreations.count + visibleRunCompletions.count
    }

    private var visibleCreations: [ProjectCreation] {
        let recent = Date().addingTimeInterval(-3600)
        return appState.activeCreations.filter { creation in
            switch creation.status {
            case .pending, .inProgress:
                return true
            case .failed, .cancelled:
                return creation.sessionId != nil
            case .completed:
                let completionDate = creation.completedAtDate ?? creation.createdAtDate ?? Date.distantPast
                return completionDate > recent
            }
        }
    }

    var body: some View {
        if hasActivity {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(AppTypography.label)
                        .foregroundColor(.hudAccent)

                    Text("Activity")
                        .font(AppTypography.labelMedium)
                        .foregroundColor(.white.opacity(0.5))

                    Text("(\(activityCount))")
                        .font(AppTypography.label)
                        .foregroundColor(.white.opacity(0.3))

                    Spacer()
                }

                ForEach(visibleCreations) { creation in
                    CreationCard(creation: creation)
                }

                ForEach(visibleRunCompletions, id: \.id) { run in
                    RunCompletionCard(run: run)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

struct CreationCard: View {
    let creation: ProjectCreation
    @Environment(AppState.self) var appState: AppState
    @State private var isHovered = false
    @State private var pulseAnimation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.15))
                        .frame(width: 32, height: 32)

                    if creation.status == .inProgress {
                        Circle()
                            .fill(statusColor.opacity(0.1))
                            .frame(width: 32, height: 32)
                            .scaleEffect(pulseAnimation ? 1.3 : 1.0)
                            .opacity(pulseAnimation ? 0 : 0.5)
                    }

                    statusIcon
                        .font(AppTypography.body)
                        .foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(creation.name)
                        .font(AppTypography.bodyMedium)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let error = creation.error {
                        Text(error)
                            .font(AppTypography.labelMedium)
                            .foregroundColor(.red.opacity(0.7))
                            .lineLimit(1)
                    } else if let progress = creation.progress {
                        Text(progress.message)
                            .font(AppTypography.labelMedium)
                            .foregroundColor(.white.opacity(0.5))
                            .lineLimit(1)
                    }
                }

                Spacer()

                actionButtons
            }

            if let progress = creation.progress, let percent = progress.percentComplete {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.white.opacity(0.1))
                            .frame(height: 3)

                        RoundedRectangle(cornerRadius: 2)
                            .fill(statusColor)
                            .frame(width: geometry.size.width * CGFloat(percent) / 100, height: 3)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.2), lineWidth: 1),
        )
        .onAppear {
            if creation.status == .inProgress {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    pulseAnimation = true
                }
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch creation.status {
            case .inProgress, .pending:
                Button(action: { appState.cancelCreation(creation.id) }) {
                    Image(systemName: "xmark")
                        .font(AppTypography.labelMedium)
                        .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.4))
                        .frame(width: 20, height: 20)
                        .background(Color.white.opacity(isHovered ? 0.1 : 0.05))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.15)) {
                        isHovered = hovering
                    }
                }

            case .failed, .cancelled:
                if appState.canResumeCreation(creation.id) {
                    Button(action: { appState.resumeCreation(creation.id) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(AppTypography.labelMedium)
                            Text("Resume")
                                .font(AppTypography.labelMedium)
                        }
                        .foregroundColor(.hudAccent)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.hudAccent.opacity(0.15))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

            case .completed:
                Button(action: { openProject() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(AppTypography.labelMedium)
                        Text("Open")
                            .font(AppTypography.labelMedium)
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.15))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func openProject() {
        if let project = appState.projects.first(where: { $0.path == creation.path }) {
            appState.launchTerminal(for: project)
        } else {
            let projectURL = URL(fileURLWithPath: creation.path)
            let projectName = projectURL.lastPathComponent.isEmpty ? creation.path : projectURL.lastPathComponent
            let adHocProject = Project(
                name: projectName,
                path: creation.path,
                displayPath: creation.path,
                lastActive: nil,
                claudeMdPath: nil,
                claudeMdPreview: nil,
                hasLocalSettings: false,
                taskCount: 0,
                stats: nil,
                isMissing: false,
            )
            appState.launchTerminal(for: adHocProject)
        }
    }

    private var statusColor: Color {
        switch creation.status {
        case .pending:
            .white.opacity(0.5)
        case .inProgress:
            .hudAccent
        case .completed:
            .green
        case .failed:
            .red
        case .cancelled:
            .orange
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch creation.status {
        case .pending:
            Image(systemName: "clock")
        case .inProgress:
            Image(systemName: "gearshape.2.fill")
                .rotationEffect(.degrees(pulseAnimation ? 360 : 0))
                .animation(.linear(duration: 3).repeatForever(autoreverses: false), value: pulseAnimation)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
        case .cancelled:
            Image(systemName: "xmark.circle.fill")
        }
    }
}

// MARK: - Run Completion Card

private struct RunCompletionCard: View {
    let run: RuntimeRunState

    private var isSuccess: Bool {
        run.status == "completed"
    }

    private var statusColor: Color {
        isSuccess ? .green : .red
    }

    private var statusIcon: String {
        switch run.status {
        case "completed":
            "checkmark.circle.fill"
        case "cancelled":
            "xmark.circle.fill"
        default:
            "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        run.methodName
    }

    private var subtitle: String {
        if isSuccess {
            return "Run completed"
        }
        if let message = run.statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty
        {
            return message
        }
        return run.status == "cancelled" ? "Run cancelled" : "Run failed"
    }

    private var elapsedLabel: String? {
        guard let start = parseISO8601Date(run.createdAt),
              let end = parseISO8601Date(run.updatedAt)
        else { return nil }
        let elapsed = end.timeIntervalSince(start)
        if elapsed < 60 {
            return "\(Int(elapsed))s"
        }
        let minutes = Int(elapsed) / 60
        let seconds = Int(elapsed) % 60
        return seconds > 0 ? "\(minutes)m \(seconds)s" : "\(minutes)m"
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: statusIcon)
                    .font(AppTypography.body)
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppTypography.bodyMedium)
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(subtitle)
                        .font(AppTypography.labelMedium)
                        .foregroundColor(isSuccess ? .white.opacity(0.5) : .red.opacity(0.7))
                        .lineLimit(1)

                    if let elapsed = elapsedLabel {
                        Text(elapsed)
                            .font(AppTypography.monoCaption)
                            .foregroundColor(.white.opacity(0.35))
                    }
                }
            }

            Spacer()
        }
        .padding(12)
        .background(Color.white.opacity(0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(statusColor.opacity(0.2), lineWidth: 1),
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(subtitle)")
        .accessibilityIdentifier(AccessibilityIdentifiers.runCompletionIdentifier)
    }
}

#Preview {
    ActivityPanel()
        .environment(AppState())
        .frame(width: 300)
        .padding()
        .background(Color.hudBackground)
}

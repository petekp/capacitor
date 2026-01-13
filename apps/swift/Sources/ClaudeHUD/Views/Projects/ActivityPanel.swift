import SwiftUI

struct ActivityPanel: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

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
        if !visibleCreations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.hudAccent)

                    Text("Activity")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))

                    Text("(\(visibleCreations.count))")
                        .font(.system(size: 10, weight: .regular))
                        .foregroundColor(.white.opacity(0.3))

                    Spacer()
                }

                ForEach(visibleCreations) { creation in
                    CreationCard(creation: creation)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

struct CreationCard: View {
    let creation: ProjectCreation
    @EnvironmentObject var appState: AppState
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
                        .font(.system(size: 14))
                        .foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(creation.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    if let error = creation.error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundColor(.red.opacity(0.7))
                            .lineLimit(1)
                    } else if let progress = creation.progress {
                        Text(progress.message)
                            .font(.system(size: 11))
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
                .stroke(statusColor.opacity(0.2), lineWidth: 1)
        )
        .onAppear {
            if creation.status == .inProgress {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                    pulseAnimation = true
                }
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        HStack(spacing: 6) {
            switch creation.status {
            case .inProgress, .pending:
                Button(action: { appState.cancelCreation(creation.id) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
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
                                .font(.system(size: 10, weight: .medium))
                            Text("Resume")
                                .font(.system(size: 10, weight: .medium))
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
                            .font(.system(size: 10, weight: .medium))
                        Text("Open")
                            .font(.system(size: 10, weight: .medium))
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
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", """
                open -a Terminal "\(creation.path)"
            """]
            try? process.run()
        }
    }

    private var statusColor: Color {
        switch creation.status {
        case .pending:
            return .white.opacity(0.5)
        case .inProgress:
            return .hudAccent
        case .completed:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .orange
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

#Preview {
    ActivityPanel()
        .environmentObject(AppState())
        .frame(width: 300)
        .padding()
        .background(Color.hudBackground)
}

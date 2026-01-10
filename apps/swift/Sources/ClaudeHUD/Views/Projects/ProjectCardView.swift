import SwiftUI

struct ProjectCardView: View {
    let project: Project
    let sessionState: ProjectSessionState?
    let projectStatus: ProjectStatus?
    let flashState: SessionState?
    let devServerPort: UInt16?
    let onTap: () -> Void
    let onInfoTap: () -> Void
    let onMoveToDormant: () -> Void
    let onOpenBrowser: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var flashOpacity: Double = 0

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(project.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)

                    Spacer()

                    if let state = sessionState {
                        StatusPillView(state: state.state)
                    }

                    if let port = devServerPort {
                        Button(action: onOpenBrowser) {
                            HStack(spacing: 4) {
                                Image(systemName: "globe")
                                    .font(.system(size: 11))
                                Text(":\(port)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(.white.opacity(isHovered ? 0.7 : 0.4))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.white.opacity(isHovered ? 0.08 : 0.04))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Open localhost:\(port) in browser")
                    }

                    Button(action: {
                        onInfoTap()
                    }) {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(isHovered ? 0.6 : 0.3))
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.plain)
                    .help("View details")
                }

                if let workingOn = sessionState?.workingOn, !workingOn.isEmpty {
                    Text(workingOn)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(2)
                }

                if let blocker = projectStatus?.blocker, !blocker.isEmpty {
                    Text(blocker)
                        .font(.system(size: 10))
                        .foregroundColor(Color(hue: 0, saturation: 0.7, brightness: 0.85))
                        .lineLimit(1)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.hudCard)
                    .shadow(color: isHovered ? Color.black.opacity(0.15) : .clear, radius: 8, y: 2)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.white.opacity(0.15) : Color.hudBorder, lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(flashState.map { Color.flashColor(for: $0) } ?? .clear, lineWidth: 2)
                    .opacity(flashOpacity)
            )
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isHovered ? Color.hudAccent.opacity(0.5) : Color.white.opacity(0.15))
                    .frame(width: 2)
                    .padding(.vertical, 12)
            }
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.snappy(duration: 0.15), value: isPressed)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(PressableButtonStyle(isPressed: $isPressed))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .onChange(of: flashState) { oldValue, newValue in
            if newValue != nil {
                withAnimation(.easeOut(duration: 0.1)) {
                    flashOpacity = 1.0
                }
                withAnimation(.easeOut(duration: 1.3).delay(0.1)) {
                    flashOpacity = 0
                }
            }
        }
        .contextMenu {
            Button(action: onTap) {
                Label("Open in Terminal", systemImage: "terminal")
            }
            if devServerPort != nil {
                Button(action: onOpenBrowser) {
                    Label("Open in Browser", systemImage: "globe")
                }
            }
            Button(action: onInfoTap) {
                Label("View Details", systemImage: "info.circle")
            }
            Divider()
            Button(action: onMoveToDormant) {
                Label("Move to Dormant", systemImage: "moon.zzz")
            }
        }
    }
}

struct StatusPillView: View {
    let state: SessionState

    var statusColor: Color {
        switch state {
        case .ready:
            return .statusReady
        case .working:
            return .statusWorking
        case .waiting:
            return .statusWaiting
        case .compacting:
            return .statusCompacting
        case .idle:
            return .statusIdle
        }
    }

    var statusText: String {
        switch state {
        case .ready:
            return "Ready"
        case .working:
            return "Working"
        case .waiting:
            return "Waiting"
        case .compacting:
            return "Compacting"
        case .idle:
            return "Idle"
        }
    }

    var isActive: Bool {
        switch state {
        case .ready, .working, .waiting, .compacting:
            return true
        case .idle:
            return false
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            BreathingDot(color: statusColor)

            Text(statusText)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(
                    isActive
                        ? AnyShapeStyle(LinearGradient(
                            colors: [statusColor, statusColor.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                          ))
                        : AnyShapeStyle(statusColor)
                )
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background {
            ZStack {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                statusColor.opacity(isActive ? 0.22 : 0.12),
                                statusColor.opacity(isActive ? 0.12 : 0.08)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if isActive {
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    statusColor.opacity(0.4),
                                    statusColor.opacity(0.15)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
            }
        }
        .shadow(color: isActive ? statusColor.opacity(0.25) : .clear, radius: 4, y: 0)
    }
}

struct PressableButtonStyle: ButtonStyle {
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, newValue in
                isPressed = newValue
            }
    }
}

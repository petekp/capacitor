import SwiftUI

struct ProjectDetailView: View {
    @EnvironmentObject var appState: AppState
    let project: Project

    @State private var isBackHovered = false
    @State private var isLaunchHovered = false
    @State private var isBrowserHovered = false
    @State private var isTerminalHovered = false

    private var devServerPort: UInt16? {
        appState.getDevServerPort(for: project)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button(action: { appState.showProjectList() }) {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Projects")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(.white.opacity(isBackHovered ? 0.9 : 0.5))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(isBackHovered ? 0.08 : 0))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isBackHovered = hovering
                        }
                    }
                    .keyboardShortcut("[", modifiers: .command)

                    Spacer()
                }

                Text(project.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.white)

                if let sessionState = appState.getSessionState(for: project) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STATUS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.5)
                            .foregroundColor(.white.opacity(0.4))

                        StatusPillView(state: sessionState.state)

                        if let workingOn = sessionState.workingOn {
                            Text(workingOn)
                                .font(.system(size: 13))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.hudCard)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.hudBorder, lineWidth: 1)
                    )
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("QUICK ACTIONS")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1.5)
                        .foregroundColor(.white.opacity(0.4))

                    HStack(spacing: 8) {
                        Button(action: { appState.launchTerminal(for: project) }) {
                            HStack(spacing: 6) {
                                Image(systemName: "terminal")
                                    .font(.system(size: 12))
                                Text("Terminal")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(.white.opacity(isTerminalHovered ? 0.9 : 0.7))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(isTerminalHovered ? 0.12 : 0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.white.opacity(isTerminalHovered ? 0.2 : 0.1), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isTerminalHovered = hovering
                            }
                        }

                        if let port = devServerPort {
                            Button(action: { appState.openInBrowser(project) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "globe")
                                        .font(.system(size: 12))
                                    Text(":\(port)")
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                }
                                .foregroundColor(.white.opacity(isBrowserHovered ? 0.9 : 0.7))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.white.opacity(isBrowserHovered ? 0.12 : 0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.white.opacity(isBrowserHovered ? 0.2 : 0.1), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .onHover { hovering in
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    isBrowserHovered = hovering
                                }
                            }
                        }
                    }

                    if devServerPort != nil {
                        Button(action: { appState.launchFullEnvironment(for: project) }) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 11))
                                Text("Launch Full Environment")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundColor(isLaunchHovered ? .white : .white.opacity(0.9))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity)
                            .background(
                                LinearGradient(
                                    colors: [
                                        Color.hudAccent.opacity(isLaunchHovered ? 0.9 : 0.7),
                                        Color.hudAccent.opacity(isLaunchHovered ? 0.7 : 0.5)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.hudAccent.opacity(isLaunchHovered ? 0.8 : 0.5), lineWidth: 1)
                            )
                            .shadow(color: Color.hudAccent.opacity(isLaunchHovered ? 0.3 : 0), radius: 8, y: 2)
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            withAnimation(.easeInOut(duration: 0.15)) {
                                isLaunchHovered = hovering
                            }
                        }
                        .help("Opens terminal and browser together")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.hudCard)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.hudBorder, lineWidth: 1)
                )

                Spacer()
            }
            .padding(16)
        }
        .background(Color.hudBackground)
    }
}

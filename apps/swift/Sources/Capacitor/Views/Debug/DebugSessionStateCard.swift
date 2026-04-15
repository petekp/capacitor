import Combine
import SwiftUI

/*
 * TRANSPARENT-UI DEBUG TOOL
 *
 * Temporary debugging visualization for session state detection. Remove when no longer needed:
 * 1. Delete this file: apps/swift/Sources/Capacitor/Views/Debug/DebugSessionStateCard.swift
 * 2. Remove usage from: apps/swift/Sources/Capacitor/Views/Debug/DebugProjectListPanel.swift
 *
 * Created for: making runtime session transitions, activity timestamps, and tool-in-flight counters visible.
 */
#if DEBUG
    struct DebugSessionStateCard: View {
        @State private var sessions: [RuntimeSession] = []
        @State private var lastUpdatedAt: Date?
        @State private var lastError: String?
        @State private var isRefreshing = false
        @State private var autoRefresh = true

        private let refreshInterval: TimeInterval = 3.0

        private var timer: Publishers.Autoconnect<Timer.TimerPublisher> {
            Timer.publish(every: refreshInterval, on: .main, in: .common).autoconnect()
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                header

                if let lastError {
                    Text("Error: \(lastError)")
                        .font(.caption2)
                        .foregroundColor(.red.opacity(0.85))
                }

                if sessions.isEmpty {
                    Text("No sessions returned by the runtime service snapshot.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                } else {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(sessions, id: \.sessionId) { session in
                                sessionRow(session)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.35))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1),
            )
            .task {
                await refreshSessions()
            }
            .onReceive(timer) { _ in
                guard autoRefresh else { return }
                _Concurrency.Task { await refreshSessions() }
            }
        }

        private var header: some View {
            HStack(alignment: .firstTextBaseline) {
                Text("Debug: Session State")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))

                if let lastUpdatedAt {
                    Text("updated \(relativeTimestamp(lastUpdatedAt))")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.55))
                }

                Spacer()

                Toggle("Auto", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .font(.caption2)

                Button(isRefreshing ? "Refreshing..." : "Refresh") {
                    _Concurrency.Task { await refreshSessions() }
                }
                .disabled(isRefreshing)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
                .buttonStyle(.plain)
            }
        }

        @MainActor
        private func refreshSessions() async {
            guard !isRefreshing else { return }
            isRefreshing = true
            defer { isRefreshing = false }

            do {
                let result = try await RuntimeClient.shared.fetchSessions()
                sessions = result.sorted { $0.updatedAt > $1.updatedAt }
                lastUpdatedAt = Date()
                lastError = nil
            } catch {
                lastError = String(describing: error)
            }
        }

        private func sessionRow(_ session: RuntimeSession) -> some View {
            let stateColor = color(for: session.state)
            let toolsInFlight = session.toolsInFlight ?? 0
            let lastActivity = session.lastActivityAt ?? "nil"
            let stateSourceLine: String = {
                guard let src = session.stateSource else { return "state_source=nil" }
                return "state_source=\(src.eventKind)/\(src.authority)"
            }()
            let lastAuthLine: String = {
                guard let ts = session.lastAuthoritativeEventAt else { return "last_auth=nil" }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                let parsed = formatter.date(from: ts) ?? ISO8601DateFormatter().date(from: ts)
                guard let when = parsed else { return "last_auth=\(ts)" }
                let ageSeconds = Date().timeIntervalSince(when)
                if ageSeconds < 60, ageSeconds >= 0 {
                    return "last_auth=\(Int(ageSeconds))s ago"
                }
                return "last_auth=\(ts)"
            }()
            let isAlive = session.isAlive.map { $0 ? "alive" : "dead" } ?? "unknown"

            return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(stateColor)
                        .frame(width: 6, height: 6)
                    Text("\(session.state.uppercased())")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                    Text(projectName(from: session.projectPath))
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text("tools=\(toolsInFlight)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                }

                Text("updated=\(session.updatedAt) state_changed=\(session.stateChangedAt)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Text("last_event=\(session.lastEvent ?? "nil") last_activity=\(lastActivity)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Text("\(stateSourceLine) pid=\(session.pid) \(isAlive)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                Text(lastAuthLine)
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        private func projectName(from path: String) -> String {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            return name.isEmpty ? path : name
        }

        private func color(for state: String) -> Color {
            switch state.lowercased() {
            case "working":
                Color.statusColor(for: .working)
            case "ready":
                Color.statusColor(for: .ready)
            case "waiting":
                Color.statusColor(for: .waiting)
            case "compacting":
                Color.statusColor(for: .compacting)
            case "idle":
                Color.statusColor(for: .idle)
            default:
                Color.white.opacity(0.5)
            }
        }

        private func relativeTimestamp(_ date: Date) -> String {
            let seconds = Int(Date().timeIntervalSince(date))
            if seconds < 5 { return "just now" }
            if seconds < 60 { return "\(seconds)s ago" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m ago" }
            let hours = minutes / 60
            return "\(hours)h ago"
        }
    }
#endif

import Combine
import Darwin
import Foundation
import SwiftUI

/*
 * TRANSPARENT-UI DEBUG TOOL
 *
 * Temporary debugging visualization for shell state detection. Remove when no longer needed:
 * 1. Delete this file: apps/swift/Sources/Capacitor/Views/Debug/DebugShellStateCard.swift
 * 2. Remove usage from: apps/swift/Sources/Capacitor/Views/Debug/DebugProjectListPanel.swift
 *
 * Created for: making runtime shell entries, liveness, and staleness visible.
 */
#if DEBUG
    struct DebugShellStateCard: View {
        @State private var shellState: ShellCwdState?
        @State private var routingDiagnostics: CoreRoutingDiagnostics?
        @State private var lastUpdatedAt: Date?
        @State private var lastError: String?
        @State private var routingDiagnosticsError: String?
        @State private var isRefreshing = false
        @State private var autoRefresh = true

        private let refreshInterval: TimeInterval = 3.0
        private let stalenessThresholdSeconds: TimeInterval = 10 * 60

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

                if shellState?.shells.isEmpty ?? true {
                    Text("No shell state entries returned by core snapshot runtime.")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                } else if let shells = shellState?.shells {
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(shells.keys.sorted(), id: \.self) { pid in
                                if let entry = shells[pid] {
                                    shellRow(pid: pid, entry: entry)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                if let diagnostics = routingDiagnostics {
                    routingDiagnosticsSection(diagnostics)
                } else if let routingDiagnosticsError {
                    Text("Routing diagnostics error: \(routingDiagnosticsError)")
                        .font(.caption2)
                        .foregroundColor(.orange.opacity(0.85))
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
                await refreshShellState()
            }
            .onReceive(timer) { _ in
                guard autoRefresh else { return }
                _Concurrency.Task { await refreshShellState() }
            }
        }

        private var header: some View {
            HStack(alignment: .firstTextBaseline) {
                Text("Debug: Shell State")
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
                    _Concurrency.Task { await refreshShellState() }
                }
                .disabled(isRefreshing)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.7))
                .buttonStyle(.plain)
            }
        }

        @MainActor
        private func refreshShellState() async {
            guard !isRefreshing else { return }
            isRefreshing = true
            defer { isRefreshing = false }

            do {
                shellState = try await RuntimeClient.shared.fetchShellState()
                lastUpdatedAt = Date()
                lastError = nil
                if let projectPath = shellState?.shells.values
                    .max(by: { $0.updatedAt < $1.updatedAt })?.cwd
                {
                    do {
                        routingDiagnostics = try await RuntimeClient.shared.fetchCoreRoutingDiagnostics(
                            projectPath: projectPath,
                            workspaceId: nil,
                        )
                        routingDiagnosticsError = nil
                    } catch {
                        routingDiagnostics = nil
                        routingDiagnosticsError = String(describing: error)
                    }
                } else {
                    routingDiagnostics = nil
                    routingDiagnosticsError = nil
                }
            } catch {
                lastError = String(describing: error)
                routingDiagnostics = nil
                routingDiagnosticsError = nil
            }
        }

        private func shellRow(pid: String, entry: ShellEntry) -> some View {
            let isLive = isLiveShell(pid: pid)
            let isStale = entry.updatedAt <= Date().addingTimeInterval(-stalenessThresholdSeconds)
            let statusColor: Color = isLive ? (isStale ? .orange : .green) : .red
            let parent = entry.parentApp ?? "unknown"
            let tmux = entry.tmuxSession ?? "nil"

            return VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text("pid=\(pid)")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                    Text(parent)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    Spacer()
                    Text(isLive ? "live" : "dead")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                    if isStale {
                        Text("stale")
                            .font(.caption2)
                            .foregroundColor(.orange.opacity(0.8))
                    }
                }

                Text("cwd=\(entry.cwd)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))

                Text("tty=\(entry.tty) tmux=\(tmux)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))

                Text("updated=\(entry.updatedAt)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }

        private func isLiveShell(pid: String) -> Bool {
            guard let pidValue = Int32(pid) else { return false }
            return kill(pidValue, 0) == 0
        }

        private func relativeTimestamp(_ date: Date) -> String {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        }

        private func routingDiagnosticsSection(_ diagnostics: CoreRoutingDiagnostics) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text("Routing diagnostics")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.72))
                Text("status=\(diagnostics.snapshot.status) confidence=\(diagnostics.snapshot.confidence) reason=\(diagnostics.snapshot.reasonCode)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.68))
                Text("scope=\(diagnostics.scopeResolution) conflicts=\(diagnostics.conflicts.count)")
                    .font(.system(size: 10, weight: .regular, design: .monospaced))
                    .foregroundColor(.white.opacity(0.62))
                ForEach(Array(diagnostics.snapshot.evidence.enumerated()), id: \.offset) { _, evidence in
                    Text("\(evidence.evidenceType)=\(evidence.value) age_ms=\(evidence.ageMs) trust=\(evidence.trustRank)")
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .padding(8)
            .background(Color.white.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }
#endif

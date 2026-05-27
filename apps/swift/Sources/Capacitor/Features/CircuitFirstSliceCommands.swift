import SwiftUI

extension Notification.Name {
    static let circuitFirstSliceDidCapture = Notification.Name("circuitFirstSliceDidCapture")
    static let circuitFirstSliceDidFail = Notification.Name("circuitFirstSliceDidFail")
}

enum CircuitFirstSliceWindowID {
    static let receiptRendering = "circuit-receipt-rendering"
    static let claudeReceiptRendering = "circuit-claude-receipt-rendering"
}

struct CircuitFirstSliceCommands: Commands {
    let appState: AppState

    var body: some Commands {
        CommandMenu("Circuit") {
            CircuitClaudeProductLoopRunButton(appState: appState)
            CircuitFirstSliceRunButton(appState: appState)
            CircuitFirstSliceRenderingMenuButton()
            CircuitClaudeProductLoopRenderingMenuButton()
        }
    }
}

private struct CircuitClaudeProductLoopRunButton: View {
    @Environment(\.openWindow) private var openWindow

    let appState: AppState

    @State private var isRunning = false

    var body: some View {
        Button(isRunning ? "Running Claude Receipt Loop..." : "Run Claude Receipt Loop") {
            run()
        }
        .disabled(isRunning)
    }

    private func run() {
        guard !isRunning else { return }
        appState.checkIdeasFileChanges()
        guard let target = Self.firstRunnableIdea(appState: appState) else {
            appState.uiState.toast = .error("Capture one receipt-first idea first")
            return
        }
        isRunning = true

        _Concurrency.Task {
            do {
                let result = try await CircuitReceiptProductLoop().run(project: target.project, idea: target.idea)
                DebugLog.write(
                    "[CircuitClaudeProductLoop] completed goalPacket=\(result.planningResponse.goalPacket.id) rawReceipt=\(result.launchResult.launch.artifacts.rawReceiptURL.path) event=\(result.agentEvent.id)",
                )
                await MainActor.run {
                    appState.uiState.toast = ToastMessage("Claude receipt captured")
                    NotificationCenter.default.post(name: .circuitFirstSliceDidCapture, object: nil)
                    openWindow(id: CircuitFirstSliceWindowID.claudeReceiptRendering)
                    isRunning = false
                }
            } catch {
                DebugLog.write("[CircuitClaudeProductLoop] failed error=\(error.localizedDescription)")
                await MainActor.run {
                    appState.uiState.toast = .error("Claude receipt loop failed")
                    isRunning = false
                }
            }
        }
    }

    private static func firstRunnableIdea(appState: AppState) -> (project: Project, idea: Idea)? {
        let capacitorRoot = ReceiptFirstProofArtifacts.defaultCapacitorRoot().standardizedFileURL.path
        if let capacitorProject = appState.projectState.projects.first(where: {
            !$0.isMissing && URL(fileURLWithPath: $0.path).standardizedFileURL.path == capacitorRoot
        }),
            let target = firstReceiptFirstIdea(in: capacitorProject, appState: appState)
        {
            return target
        }

        let candidateProjects: [Project] = if let activeProject = appState.activeProjectResolver.activeProject {
            [activeProject] + appState.projectState.projects.filter { $0.path != activeProject.path }
        } else {
            appState.projectState.projects
        }

        for project in candidateProjects where !project.isMissing {
            if let target = firstReceiptFirstIdea(in: project, appState: appState) {
                return target
            }
        }
        return nil
    }

    private static func firstReceiptFirstIdea(in project: Project, appState: AppState) -> (project: Project, idea: Idea)? {
        let ideas = appState.getIdeas(for: project).filter(isReceiptFirstIdea)
        if let queued = ideas.first(where: IdeaQueueMetrics.isQueued) {
            return (project, queued)
        }
        if let first = ideas.first {
            return (project, first)
        }
        return nil
    }

    private static func isReceiptFirstIdea(_ idea: Idea) -> Bool {
        let text = "\(idea.title)\n\(idea.description)".lowercased()
        return text.contains("receipt-first capacitor <-> circuit slice")
    }
}

private struct CircuitFirstSliceRunButton: View {
    @Environment(\.openWindow) private var openWindow

    let appState: AppState

    @State private var isRunning = false

    var body: some View {
        Button(isRunning ? "Running Receipt-First Slice..." : "Run Receipt-First Slice") {
            run()
        }
        .disabled(isRunning)
    }

    private func run() {
        guard !isRunning else { return }
        isRunning = true

        _Concurrency.Task {
            do {
                let result = try await ReceiptFirstProofAdapter().launchAndWaitForCapture()
                DebugLog.write(
                    "[CircuitFirstSlice] completed goalPacket=\(result.launch.packet.id) rawReceipt=\(result.launch.artifacts.rawReceiptURL.path)",
                )
                await MainActor.run {
                    appState.uiState.toast = ToastMessage("Circuit receipt captured")
                    NotificationCenter.default.post(name: .circuitFirstSliceDidCapture, object: nil)
                    openWindow(id: CircuitFirstSliceWindowID.receiptRendering)
                    isRunning = false
                }
            } catch {
                DebugLog.write("[CircuitFirstSlice] failed error=\(error.localizedDescription)")
                await MainActor.run {
                    appState.uiState.toast = .error("Circuit receipt failed")
                    isRunning = false
                }
            }
        }
    }
}

struct CircuitFirstSliceRenderingMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Receipt-First Result") {
            NotificationCenter.default.post(name: .circuitFirstSliceDidCapture, object: nil)
            openWindow(id: CircuitFirstSliceWindowID.receiptRendering)
        }
    }
}

struct CircuitClaudeProductLoopRenderingMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Claude Receipt Loop Result") {
            NotificationCenter.default.post(name: .circuitFirstSliceDidCapture, object: nil)
            openWindow(id: CircuitFirstSliceWindowID.claudeReceiptRendering)
        }
    }
}

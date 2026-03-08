import SwiftUI

enum AppDebugSupport {
    static func restoreOnboardingBackup() {
        #if DEBUG
            let fm = FileManager.default
            let capacitorPath = fm.homeDirectoryForCurrentUser.appendingPathComponent(".capacitor")
            let backupPath = onboardingBackupPath

            guard fm.fileExists(atPath: backupPath.path) else { return }

            let userDataFiles = ["projects.json", "creations.json"]
            for filename in userDataFiles {
                let sourcePath = backupPath.appendingPathComponent(filename)
                let destPath = capacitorPath.appendingPathComponent(filename)
                if fm.fileExists(atPath: sourcePath.path) {
                    try? fm.copyItem(at: sourcePath, to: destPath)
                    print("[Debug] Restored \(filename) from backup")
                }
            }

            try? fm.removeItem(at: backupPath)
            print("[Debug] Cleaned up onboarding backup")
        #endif
    }

    #if DEBUG
        static let onboardingBackupPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".capacitor-onboarding-backup")
    #endif
}

#if DEBUG
    struct AppDebugCommands: Commands {
        let appState: AppState
        @Binding var setupComplete: Bool
        @AppStorage("debugShowProjectListDiagnostics") private var debugShowProjectListDiagnostics = true

        var body: some Commands {
            CommandMenu("Debug") {
                ProjectDebugPanelMenuButton()
                UITuningPanelMenuButton()

                Divider()

                Toggle("Show Diagnostics in Project List", isOn: $debugShowProjectListDiagnostics)

                Divider()

                Section("Toast Testing") {
                    Button("Toast: 1 failed") {
                        appState.toast = .error("project-a failed")
                    }
                    Button("Toast: 2 failed, 1 added") {
                        appState.toast = .error("project-a, project-b failed (1 added)")
                    }
                    Button("Toast: 5 failed, 3 added") {
                        appState.toast = .error("project-a, project-b and 3 more failed (3 added)")
                    }
                    Button("Toast: Already linked") {
                        appState.toast = ToastMessage("Already linked!")
                    }
                    Button("Toast: Moved to In Progress") {
                        appState.toast = ToastMessage("Moved to In Progress")
                    }
                }

                Divider()

                Section("Tooltip Testing") {
                    Button("Show Drag-Drop Tip Now") {
                        appState.projectActionState.pendingDragDropTip = true
                    }
                    Button("Reset Tip Flag (hasSeenDragDropTip)") {
                        UserDefaults.standard.removeObject(forKey: "hasSeenDragDropTip")
                    }
                }

                Divider()

                Button("Return to Setup Screen") {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        setupComplete = false
                    }
                }
                .keyboardShortcut("W", modifiers: [.command, .shift, .option])

                Button("Reset Onboarding (Full)") {
                    resetOnboardingFully()
                }
                .keyboardShortcut("R", modifiers: [.command, .shift, .option])

                Divider()

                Button("Clear All Projects (Empty State)") {
                    for project in appState.projectWorkflowState.projectCatalog {
                        appState.projectActionState.removeProject(path: project.path)
                    }
                }
                Button("Connect Project via File Browser") {
                    appState.projectImportCoordinator.connectViaFileBrowser()
                }
            }
        }

        private func resetOnboardingFully() {
            _Concurrency.Task {
                let fm = FileManager.default
                let home = fm.homeDirectoryForCurrentUser
                let capacitorPath = home.appendingPathComponent(".capacitor")
                let backupPath = AppDebugSupport.onboardingBackupPath

                let userDataFiles = ["projects.json", "creations.json"]
                try? fm.removeItem(at: backupPath)
                try? fm.createDirectory(at: backupPath, withIntermediateDirectories: true)

                for filename in userDataFiles {
                    let sourcePath = capacitorPath.appendingPathComponent(filename)
                    let destPath = backupPath.appendingPathComponent(filename)
                    if fm.fileExists(atPath: sourcePath.path) {
                        try? fm.copyItem(at: sourcePath, to: destPath)
                        print("[Debug] Backed up \(filename)")
                    }
                }

                try? fm.removeItem(at: capacitorPath)
                print("[Debug] Removed ~/.capacitor/")

                await removeHooksFromSettings()

                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        setupComplete = false
                    }
                }

                print("[Debug] Onboarding reset complete (user data backed up to ~/.capacitor-onboarding-backup/)")
            }
        }

        private func removeHooksFromSettings() async {
            do {
                let engine = try CoreRuntime()
                let result = try engine.removeHooks()
                print("[Debug] \(result.message)")
            } catch {
                print("[Debug] Failed to remove hooks: \(error)")
            }
        }
    }

    struct AppDebugWindows: Scene {
        let appState: AppState

        var body: some Scene {
            Window("UI Tuning", id: "ui-tuning-panel") {
                UITuningPanel()
                    .preferredColorScheme(.dark)
            }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .defaultPosition(.topTrailing)
            .defaultSize(width: 580, height: 720)
            .suppressedFromWindowMenu()

            Window("Project Debug Panel", id: "project-debug-panel") {
                DebugProjectListPanel()
                    .environment(appState)
                    .preferredColorScheme(.dark)
            }
            .windowStyle(.hiddenTitleBar)
            .windowResizability(.contentSize)
            .defaultPosition(.topTrailing)
            .defaultSize(width: 360, height: 520)
            .suppressedFromWindowMenu()
        }
    }

    struct UITuningPanelMenuButton: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("UI Tuning Panel") {
                openWindow(id: "ui-tuning-panel")
            }
            .keyboardShortcut("U", modifiers: [.command, .shift])
        }
    }

    struct ProjectDebugPanelMenuButton: View {
        @Environment(\.openWindow) private var openWindow

        var body: some View {
            Button("Project Debug Panel") {
                openWindow(id: "project-debug-panel")
            }
            .keyboardShortcut("D", modifiers: [.command, .shift])
        }
    }
#endif

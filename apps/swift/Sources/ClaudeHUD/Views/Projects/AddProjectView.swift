import SwiftUI
import UniformTypeIdentifiers

struct AddProjectView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    @State private var appeared = false
    @State private var isDragHovered = false
    @State private var validationResult: ValidationResultFfi?
    @State private var showingValidation = false
    @State private var pendingPath: String?

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                BackButton(title: "Add Project") {
                    appState.showAddProject()
                }
                .keyboardShortcut("[", modifiers: .command)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            Spacer()

            if showingValidation, let result = validationResult {
                validationResultView(result)
            } else {
                dropZoneView
            }

            Spacer()
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.15)) {
                appeared = true
            }
            // Check for pending path from HeaderView's folder picker
            if let path = appState.pendingProjectPath {
                appState.pendingProjectPath = nil  // Consume it
                validateAndShow(path)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $isDragHovered) { providers in
            handleDrop(providers)
        }
    }

    // MARK: - Drop Zone View

    private var dropZoneView: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.hudAccent.opacity(0.08))
                    .frame(width: 100, height: 100)
                    .blur(radius: 25)
                    .scaleEffect(appeared ? 1.0 : 0.5)
                    .opacity(appeared ? 1 : 0)

                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                        )
                        .foregroundColor(.white.opacity(isDragHovered ? 0.4 : 0.15))

                    VStack(spacing: 14) {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(isDragHovered ? 0.7 : 0.4),
                                        .white.opacity(isDragHovered ? 0.5 : 0.25)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .scaleEffect(isDragHovered ? 1.1 : 1.0)

                        VStack(spacing: 4) {
                            Text("Drop folder here")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))

                            Text("or click to browse")
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.35))
                        }
                    }
                }
                .frame(width: 180, height: 140)
                .scaleEffect(appeared ? 1.0 : 0.9)
                .opacity(appeared ? 1 : 0)
                .contentShape(Rectangle())
                .onTapGesture {
                    showFolderPicker()
                }
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isDragHovered)
    }

    // MARK: - Validation Result View

    @ViewBuilder
    private func validationResultView(_ result: ValidationResultFfi) -> some View {
        VStack(spacing: 20) {
            validationIcon(for: result.resultType)
                .scaleEffect(appeared ? 1.0 : 0.8)
                .opacity(appeared ? 1 : 0)

            VStack(spacing: 8) {
                Text(validationTitle(for: result))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))

                if let reason = result.reason {
                    Text(reason)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }

                Text(displayPath(result.path))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 280)
            }

            validationActions(for: result)
        }
        .padding(.horizontal, 20)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showingValidation)
    }

    private func validationIcon(for resultType: String) -> some View {
        let (icon, color): (String, Color) = switch resultType {
        case "valid":
            ("checkmark.circle.fill", .green)
        case "suggest_parent":
            ("arrow.up.circle.fill", .orange)
        case "missing_claude_md":
            ("doc.badge.plus", .yellow)
        case "not_a_project":
            ("questionmark.folder.fill", .gray)
        case "path_not_found":
            ("xmark.circle.fill", .red)
        case "dangerous_path":
            ("exclamationmark.triangle.fill", .red)
        case "already_tracked":
            ("checkmark.circle.fill", .hudAccent)
        default:
            ("folder.fill", .white)
        }

        return Image(systemName: icon)
            .font(.system(size: 48, weight: .light))
            .foregroundColor(color.opacity(0.8))
    }

    private func validationTitle(for result: ValidationResultFfi) -> String {
        switch result.resultType {
        case "valid":
            return result.hasClaudeMd ? "Ready to Add" : "Valid Project"
        case "suggest_parent":
            return "Did You Mean...?"
        case "missing_claude_md":
            return "Missing CLAUDE.md"
        case "not_a_project":
            return "Not a Project"
        case "path_not_found":
            return "Path Not Found"
        case "dangerous_path":
            return "Path Too Broad"
        case "already_tracked":
            return "Already Tracked"
        default:
            return "Validation Result"
        }
    }

    @ViewBuilder
    private func validationActions(for result: ValidationResultFfi) -> some View {
        HStack(spacing: 12) {
            switch result.resultType {
            case "valid":
                Button("Add Project") {
                    addProjectAndReturn(result.path)
                }
                .buttonStyle(ValidationPrimaryButtonStyle())

            case "suggest_parent":
                if let suggested = result.suggestedPath {
                    VStack(spacing: 8) {
                        Text("Suggested: \(displayPath(suggested))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.hudAccent.opacity(0.8))

                        HStack(spacing: 12) {
                            Button("Use Suggested") {
                                validateAndShow(suggested)
                            }
                            .buttonStyle(ValidationPrimaryButtonStyle())

                            Button("Use Original") {
                                forceAdd(result.path)
                            }
                            .buttonStyle(ValidationSecondaryButtonStyle())
                        }
                    }
                }

            case "missing_claude_md":
                VStack(spacing: 8) {
                    Button("Create CLAUDE.md & Add") {
                        if appState.createClaudeMd(for: result.path) {
                            addProjectAndReturn(result.path)
                        }
                    }
                    .buttonStyle(ValidationPrimaryButtonStyle())

                    Button("Add Without CLAUDE.md") {
                        addProjectAndReturn(result.path)
                    }
                    .buttonStyle(ValidationSecondaryButtonStyle())
                }

            case "not_a_project":
                VStack(spacing: 8) {
                    Button("Create CLAUDE.md & Add") {
                        if appState.createClaudeMd(for: result.path) {
                            addProjectAndReturn(result.path)
                        }
                    }
                    .buttonStyle(ValidationPrimaryButtonStyle())

                    Button("Choose Different Folder") {
                        resetValidation()
                    }
                    .buttonStyle(ValidationSecondaryButtonStyle())
                }

            case "path_not_found", "dangerous_path":
                Button("Choose Different Folder") {
                    resetValidation()
                }
                .buttonStyle(ValidationSecondaryButtonStyle())

            case "already_tracked":
                VStack(spacing: 8) {
                    Button("Go to Project") {
                        goToExistingProject(path: result.path)
                    }
                    .buttonStyle(ValidationPrimaryButtonStyle())

                    Button("Choose Different Folder") {
                        resetValidation()
                    }
                    .buttonStyle(ValidationSecondaryButtonStyle())
                }

            default:
                EmptyView()
            }
        }

        Button("Cancel") {
            resetValidation()
        }
        .buttonStyle(ValidationTextButtonStyle())
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func showFolderPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a project folder to add"
        panel.prompt = "Select"

        if panel.runModal() == .OK, let url = panel.url {
            validateAndShow(url.path)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
            guard let data = data as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else { return }

            DispatchQueue.main.async {
                validateAndShow(url.path)
            }
        }
        return true
    }

    private func validateAndShow(_ path: String) {
        pendingPath = path
        validationResult = appState.validateProject(path)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showingValidation = true
        }
    }

    private func addProjectAndReturn(_ path: String) {
        appState.addProject(path)
        appState.showProjectList()
    }

    private func forceAdd(_ path: String) {
        appState.addProject(path)
        appState.showProjectList()
    }

    private func resetValidation() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showingValidation = false
            validationResult = nil
            pendingPath = nil
        }
    }

    private func goToExistingProject(path: String) {
        if let project = appState.projects.first(where: { $0.path == path }) {
            appState.showProjectDetail(project)
        } else {
            appState.showProjectList()
        }
    }

    private func displayPath(_ path: String) -> String {
        if let home = FileManager.default.homeDirectoryForCurrentUser.path as String?,
           path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Button Styles

private struct ValidationPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.hudAccent.opacity(configuration.isPressed ? 0.6 : 0.8))
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

private struct ValidationSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.7))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(configuration.isPressed ? 0.1 : 0.05))
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
    }
}

private struct ValidationTextButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(configuration.isPressed ? 0.3 : 0.4))
    }
}

import SwiftUI

struct NewIdeaView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    @State private var projectName = ""
    @State private var projectDescription = ""
    @State private var selectedLanguage: String?
    @State private var framework = ""
    @State private var isCreating = false
    @State private var error: String?
    @State private var appeared = false

    private let languages = ["TypeScript", "Python", "Rust", "Go", "JavaScript"]
    private let defaultLocation = "~/Code"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton(title: "Add Project") {
                    appState.showAddProject()
                }
                .keyboardShortcut("[", modifiers: .command)

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    headerSection
                    formSection
                    if let error = error {
                        errorSection(error)
                    }
                    createButton
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.1)) {
                appeared = true
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(Color.hudAccent.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.hudAccent)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("New Idea")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)

                    Text("Claude will build a working v1")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.5))
                }
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
    }

    private var formSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Name")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .textCase(.uppercase)

                TextField("my-awesome-project", text: $projectName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .padding(10)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("What do you want to build?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .textCase(.uppercase)

                TextEditor(text: $projectDescription)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 80, maxHeight: 120)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Language (optional)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                    .textCase(.uppercase)

                HStack(spacing: 8) {
                    ForEach(languages, id: \.self) { language in
                        languageChip(language)
                    }
                }
            }

            if selectedLanguage != nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Framework (optional)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.5))
                        .textCase(.uppercase)

                    TextField("e.g., Next.js, FastAPI, Actix", text: $framework)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(10)
                        .background(Color.white.opacity(0.05))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                        )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.15), value: appeared)
    }

    private func languageChip(_ language: String) -> some View {
        let isSelected = selectedLanguage == language

        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                if isSelected {
                    selectedLanguage = nil
                } else {
                    selectedLanguage = language
                }
            }
        }) {
            Text(language)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .hudBackground : .white.opacity(0.7))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isSelected ? Color.hudAccent : Color.white.opacity(0.08))
                .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    private func errorSection(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 12))
                .foregroundColor(.orange.opacity(0.9))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private var createButton: some View {
        Button(action: createProject) {
            HStack(spacing: 8) {
                if isCreating {
                    ProgressView()
                        .scaleEffect(0.8)
                        .progressViewStyle(CircularProgressViewStyle(tint: .hudBackground))
                    Text("Creating...")
                } else {
                    Image(systemName: "sparkles")
                    Text("Create Project")
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundColor(.hudBackground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                isFormValid
                    ? Color.hudAccent
                    : Color.hudAccent.opacity(0.3)
            )
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(!isFormValid || isCreating)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared ? 0 : 10)
        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(0.2), value: appeared)
    }

    private var isFormValid: Bool {
        !projectName.trimmingCharacters(in: .whitespaces).isEmpty &&
        !projectDescription.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func createProject() {
        guard isFormValid else { return }

        isCreating = true
        error = nil

        let request = NewProjectRequest(
            name: projectName.trimmingCharacters(in: .whitespaces),
            description: projectDescription.trimmingCharacters(in: .whitespaces),
            location: defaultLocation,
            language: selectedLanguage?.lowercased(),
            framework: framework.isEmpty ? nil : framework
        )

        appState.createProjectFromIdea(request) { result in
            isCreating = false

            if result.success {
                appState.loadDashboard()
                appState.showProjectList()
            } else {
                error = result.error ?? "Failed to create project"
            }
        }
    }
}


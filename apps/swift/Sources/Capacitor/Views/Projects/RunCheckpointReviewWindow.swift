import SwiftUI

struct RunCheckpointReviewWindow: View {
    @Environment(AppState.self) private var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var manifest: DelegationReviewManifest?
    @State private var manifestLoadError: String?
    @State private var note = ""
    @State private var phase: RunCheckpointReviewPhase = .review

    private struct Context {
        let target: AppState.RunCheckpointWindowTarget
        let run: RuntimeRunState
        let checkpoint: RuntimeCheckpointState
        let projectName: String
    }

    private var target: AppState.RunCheckpointWindowTarget? {
        appState.uiState.runCheckpointWindowTarget
    }

    private var context: Context? {
        guard let target,
              let run = appState.runState(projectPath: target.projectPath, runID: target.runID),
              let checkpoint = appState.runCheckpointState(target: target)
        else {
            return nil
        }

        return Context(
            target: target,
            run: run,
            checkpoint: checkpoint,
            projectName: projectName(for: target.projectPath),
        )
    }

    private var isSubmitting: Bool {
        if case .submitting = phase {
            return true
        }
        return false
    }

    private var targetIdentity: String? {
        guard let target else { return nil }
        return "\(target.projectPath)#\(target.runID)#\(target.checkpointID)"
    }

    private var resolvedCheckpointID: String? {
        context?.checkpoint.id
    }

    var body: some View {
        Group {
            if case .submitted = phase {
                submittedReceiptView
            } else if let context {
                HStack(spacing: 0) {
                    contentPane(context: context)
                        .frame(minWidth: 420)

                    Divider()
                        .background(Color.white.opacity(0.08))

                    decisionRail(context: context)
                        .frame(width: 320)
                }
            } else {
                emptyStateView
            }
        }
        .background {
            ZStack {
                DarkFrostedGlass()
                Color.black.opacity(0.15)
            }
            .ignoresSafeArea()
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.runCheckpointReviewIdentifier)
        .task(id: targetIdentity ?? "no-checkpoint") {
            await loadManifest()
        }
        .onChange(of: appState.uiState.runCheckpointWindowTarget) { _, newValue in
            if newValue == nil {
                dismissWindow(id: "run-checkpoint-review")
            }
        }
        .onChange(of: resolvedCheckpointID) { oldValue, newValue in
            if oldValue != nil, newValue == nil {
                dismissWindow(id: "run-checkpoint-review")
            }
        }
        .onChange(of: targetIdentity) { oldValue, newValue in
            guard oldValue != newValue else { return }
            phase = .review
            note = ""
            manifestLoadError = nil
        }
        .onDisappear {
            appState.uiState.runCheckpointWindowTarget = nil
        }
    }

    private func contentPane(context: Context) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(context.projectName)
                        .font(AppTypography.sectionTitle.monospaced())
                        .foregroundColor(.white.opacity(0.9))

                    HStack(spacing: 8) {
                        Text("Run Checkpoint")
                            .font(AppTypography.caption.weight(.bold))
                            .tracking(2)
                            .foregroundColor(.orange.opacity(0.85))

                        Text(context.run.methodName)
                            .font(AppTypography.caption.weight(.medium))
                            .foregroundColor(.white.opacity(0.5))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(
                                Capsule()
                                    .fill(Color.white.opacity(0.08)),
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(context.checkpoint.title)
                        .font(AppTypography.cardTitle)
                        .foregroundColor(.white.opacity(0.94))

                    Text(checkpointSummary(for: context))
                        .font(AppTypography.body)
                        .foregroundColor(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack(spacing: 16) {
                    metadataItem(label: "Run", value: context.run.id)
                    metadataItem(label: "Kind", value: checkpointKindLabel(context.checkpoint.kind))
                    metadataItem(label: "Created", value: createdAtLabel(context.checkpoint.createdAt))
                }
                .font(AppTypography.monoCaption)
                .foregroundColor(.white.opacity(0.4))

                if let manifestLoadError {
                    banner(
                        title: "Manifest unavailable",
                        message: manifestLoadError,
                        tint: .orange,
                    )
                }

                Divider()
                    .background(Color.white.opacity(0.08))

                if let artifacts = manifest?.artifacts, !artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("ARTIFACTS")

                        VStack(spacing: 6) {
                            ForEach(artifacts) { artifact in
                                artifactCard(
                                    label: artifact.label,
                                    path: artifact.path,
                                )
                            }
                        }
                    }
                }

                if let artifacts = manifest?.artifacts {
                    let mediaArtifacts = artifacts.filter(\.isMedia)
                    if !mediaArtifacts.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            sectionLabel("MEDIA")

                            ForEach(mediaArtifacts) { artifact in
                                CaptureImageView(
                                    filePath: artifact.path,
                                    label: artifact.label,
                                )
                            }
                        }
                    }
                }

                let checkpointScreenshots = context.checkpoint.mediaArtifacts.filter { $0.artifactType == "screenshot" }
                if !checkpointScreenshots.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("CHECKPOINT MEDIA")

                        ForEach(checkpointScreenshots, id: \.path) { artifact in
                            CaptureImageView(
                                filePath: artifact.path,
                                label: artifact.label,
                            )
                        }
                    }
                }

                if !context.checkpoint.mermaidSources.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("MERMAID SOURCES")

                        ForEach(context.checkpoint.mermaidSources, id: \.label) { source in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.label)
                                    .font(AppTypography.bodySecondary.weight(.medium))
                                    .foregroundColor(.white.opacity(0.9))

                                ScrollView(.horizontal, showsIndicators: true) {
                                    Text(source.source)
                                        .font(AppTypography.monoCaption)
                                        .foregroundColor(.white.opacity(0.65))
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.04))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
                                    ),
                            )
                        }
                    }
                }

                if manifest == nil,
                   context.checkpoint.mediaArtifacts.isEmpty,
                   context.checkpoint.mermaidSources.isEmpty
                {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("ARTIFACTS")

                        Text("No checkpoint artifacts are available yet.")
                            .font(AppTypography.body)
                            .foregroundColor(.white.opacity(0.55))
                    }
                }
            }
            .padding(24)
        }
    }

    private func decisionRail(context: Context) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Decision")
                .font(AppTypography.cardTitle)
                .foregroundColor(.white.opacity(0.7))

            if case let .failed(message) = phase {
                banner(
                    title: "Submission failed",
                    message: message,
                    tint: .red,
                )
            }

            decisionHintCard(
                title: manifest?.decisions?.approve?.label ?? "Approve",
                description: manifest?.decisions?.approve?.description ?? "Accept this checkpoint and let the run continue.",
                icon: "checkmark.circle.fill",
                accentColor: .green,
            )

            decisionHintCard(
                title: manifest?.decisions?.requestChanges?.label ?? "Request Changes",
                description: manifest?.decisions?.requestChanges?.description ?? "Send the run back with guidance for another pass.",
                icon: "arrow.triangle.2.circlepath",
                accentColor: .orange,
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("Optional Note")
                    .font(AppTypography.caption.weight(.semibold))
                    .foregroundColor(.white.opacity(0.55))

                ZStack(alignment: .topLeading) {
                    if note.isEmpty {
                        Text("Add context for the decision.")
                            .font(AppTypography.body)
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 18)
                    }

                    TextEditor(text: $note)
                        .font(AppTypography.body)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 120)
                        .disabled(isSubmitting)
                        .accessibilityIdentifier(AccessibilityIdentifiers.runCheckpointNotesIdentifier)
                }
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5),
                        ),
                )
            }

            Spacer()

            VStack(spacing: 10) {
                decisionButton(
                    title: manifest?.decisions?.requestChanges?.label ?? "Request Changes",
                    icon: "arrow.triangle.2.circlepath",
                    foreground: .white.opacity(0.9),
                    background: Color.orange.opacity(0.65),
                    accessibilityIdentifier: AccessibilityIdentifiers.runCheckpointRequestChangesIdentifier,
                    isPrimary: false,
                ) {
                    submitDecision(.requestChanges, context: context)
                }

                decisionButton(
                    title: manifest?.decisions?.approve?.label ?? "Approve",
                    icon: "checkmark.circle.fill",
                    foreground: .black.opacity(0.88),
                    background: Color.white.opacity(0.92),
                    accessibilityIdentifier: AccessibilityIdentifiers.runCheckpointApproveIdentifier,
                    isPrimary: true,
                ) {
                    submitDecision(.approve, context: context)
                }
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.2))
    }

    private func decisionButton(
        title: String,
        icon: String,
        foreground: Color,
        background: Color,
        accessibilityIdentifier: String,
        isPrimary: Bool,
        action: @escaping () -> Void,
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if case let .submitting(decision) = phase,
                   decision.isPrimary == isPrimary
                {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foreground)
                } else {
                    Image(systemName: icon)
                        .font(AppTypography.bodySecondary)
                }

                Text(buttonTitle(baseTitle: title, isPrimary: isPrimary))
                    .font(AppTypography.bodyMedium)
            }
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5),
                    ),
            )
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var submittedReceiptView: some View {
        VStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(AppTypography.sectionTitle.weight(.semibold))
                        .foregroundColor(.blue.opacity(0.7))

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Decision submitted")
                            .font(AppTypography.sectionTitle)
                            .foregroundColor(.white.opacity(0.9))

                        Text("Waiting for the runtime snapshot to clear this checkpoint.")
                            .font(AppTypography.body)
                            .foregroundColor(.white.opacity(0.72))
                    }
                }

                Text("This window closes automatically once the active checkpoint disappears from the run snapshot.")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.58))
            }
            .padding(24)
            .frame(maxWidth: 440, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.black.opacity(0.2))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5),
                    ),
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Text("No active run checkpoint")
                .font(AppTypography.sectionTitle)
                .foregroundColor(.white.opacity(0.7))

            Text("The checkpoint may have been resolved or the run resumed.")
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitDecision(
        _ decision: RunCheckpointDecision,
        context: Context,
    ) {
        phase = .submitting(decision)

        _Concurrency.Task { @MainActor in
            do {
                try await appState.submitRunCheckpointDecision(
                    projectPath: context.target.projectPath,
                    runID: context.target.runID,
                    checkpointID: context.target.checkpointID,
                    action: decision.rawValue,
                    note: note.isEmpty ? nil : note,
                )
                phase = .submitted(decision)
                appState.refreshSessionStates()
            } catch {
                phase = .failed(Self.submissionFailureMessage(for: error))
            }
        }
    }

    private func loadManifest() async {
        guard let checkpoint = context?.checkpoint else {
            await MainActor.run {
                manifest = nil
                manifestLoadError = nil
            }
            return
        }

        guard let manifestPath = checkpoint.manifestPath,
              !manifestPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            await MainActor.run {
                manifest = nil
                manifestLoadError = nil
            }
            return
        }

        let manifestURL = URL(fileURLWithPath: manifestPath)

        do {
            let data = try Data(contentsOf: manifestURL)
            let decodedManifest = try JSONDecoder().decode(DelegationReviewManifest.self, from: data)
            await MainActor.run {
                manifest = decodedManifest
                manifestLoadError = nil
            }
        } catch {
            await MainActor.run {
                manifest = nil
                manifestLoadError = error.localizedDescription
            }
        }
    }

    private func projectName(for projectPath: String) -> String {
        if let project = appState.projectState.projects.first(where: { $0.path == projectPath }) {
            return project.name
        }

        let lastPathComponent = URL(fileURLWithPath: projectPath).lastPathComponent
        return lastPathComponent.isEmpty ? projectPath : lastPathComponent
    }

    private func checkpointSummary(for context: Context) -> String {
        if let summary = manifest?.summary, !summary.isEmpty {
            return summary
        }
        if let summary = context.checkpoint.summary, !summary.isEmpty {
            return summary
        }
        return "This run is paused and waiting for your decision."
    }

    private func checkpointKindLabel(_ kind: RuntimeCheckpointKind) -> String {
        switch kind {
        case .proposal:
            "Proposal"
        case .implementationMilestone:
            "Implementation"
        case .alignmentReview:
            "Alignment"
        case let .custom(label):
            label
        }
    }

    private func createdAtLabel(_ timestamp: String) -> String {
        guard let date = parseISO8601Date(timestamp) else {
            return timestamp
        }
        return runCheckpointTimestampFormatter.string(from: date)
    }

    private func buttonTitle(baseTitle: String, isPrimary: Bool) -> String {
        if case let .submitting(decision) = phase,
           decision.isPrimary == isPrimary
        {
            return "Submitting..."
        }
        return baseTitle
    }

    private func metadataItem(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundColor(.white.opacity(0.4))
            Text(value)
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private func artifactCard(
        label: String,
        path: String,
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(AppTypography.bodySecondary)
                .foregroundColor(.white.opacity(0.45))

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(AppTypography.bodySecondary.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
                Text(path)
                    .font(AppTypography.monoCaption)
                    .foregroundColor(.white.opacity(0.4))
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5),
                ),
        )
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.orange.opacity(0.6))
                .frame(width: 4, height: 4)

            Text(title)
                .font(AppTypography.caption.weight(.bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.4))
        }
    }

    private func decisionHintCard(
        title: String,
        description: String,
        icon: String,
        accentColor: Color,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(AppTypography.sectionTitle)
                    .foregroundColor(accentColor.opacity(0.85))

                Text(title)
                    .font(AppTypography.bodySecondary.weight(.semibold))
                    .foregroundColor(.white.opacity(0.9))

                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accentColor.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(accentColor.opacity(0.3), lineWidth: 0.5),
                    ),
            )

            Text(description)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.45))
                .padding(.horizontal, 4)
        }
    }

    private func banner(
        title: String,
        message: String,
        tint: Color,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(AppTypography.bodySecondary.weight(.semibold))
                .foregroundColor(.white.opacity(0.9))

            Text(message)
                .font(AppTypography.caption)
                .foregroundColor(.white.opacity(0.68))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.22), lineWidth: 1),
                ),
        )
    }

    private static func submissionFailureMessage(for error: Error) -> String {
        switch error {
        case RuntimeClientError.disabled:
            "The runtime service is disabled."
        case let RuntimeClientError.mutationRejected(message):
            message
        case let RuntimeClientError.runtimeUnavailable(message):
            message
        case RuntimeClientError.invalidResponse:
            "The runtime service returned an invalid response."
        case RuntimeClientError.timeout:
            "The runtime service timed out."
        default:
            error.localizedDescription
        }
    }
}

private enum RunCheckpointDecision: String, Equatable {
    case approve
    case requestChanges = "request_changes"

    var isPrimary: Bool {
        self == .approve
    }
}

private enum RunCheckpointReviewPhase: Equatable {
    case review
    case submitting(RunCheckpointDecision)
    case submitted(RunCheckpointDecision)
    case failed(String)
}

private let runCheckpointTimestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()

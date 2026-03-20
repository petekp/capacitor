import SwiftUI

struct DelegationReviewWindow: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var reviewBrief = ""
    @State private var manifest: DelegationReviewManifest?
    @State private var previousDecision: PreviousRoundDecision?
    @State private var selectedDecision: DecisionOption?
    @State private var note = ""
    @State private var diffStat = ""
    @State private var fullDiff = ""
    @State private var showFullDiff = false
    @State private var swiftChangesBannerDismissed = false

    private var target: AppState.ReviewWindowTarget? {
        appState.reviewWindowTarget
    }

    private var delegation: RuntimeDelegationState? {
        guard let target else { return nil }
        return appState.delegationState(forPath: target.projectPath)
    }

    private var currentReview: RuntimeDelegationReview? {
        delegation?.currentReview
    }

    private var project: Project? {
        guard let target else { return nil }
        return appState.projects.first { $0.path == target.projectPath }
    }

    private var milestoneNumber: Int {
        guard let milestoneId = currentReview?.milestoneId else { return 1 }
        return Int(milestoneId) ?? 1
    }

    var body: some View {
        Group {
            if let project, let delegation, let currentReview {
                HStack(spacing: 0) {
                    contentPane(project: project, delegation: delegation, review: currentReview)
                        .frame(minWidth: 400)

                    Divider()
                        .background(Color.white.opacity(0.08))

                    decisionRail(project: project, delegation: delegation)
                        .frame(width: 300)
                }
            } else if target != nil, delegation != nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white.opacity(0.5))
                    Text("Decision submitted")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.65))
                    Text("The worker is processing your feedback.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.42))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 12) {
                    Text("No active review")
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.65))
                    Text("The review may have been completed or cancelled.")
                        .font(.body)
                        .foregroundColor(.white.opacity(0.42))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.hudBackground)
        .accessibilityIdentifier(AccessibilityIdentifiers.delegationReviewIdentifier)
        .task(id: currentReview?.manifestPath ?? "no-review") {
            await loadReviewArtifacts()
        }
        .onChange(of: appState.reviewWindowTarget) { _, newValue in
            if newValue == nil {
                dismissWindow(id: "delegation-review")
            }
        }
        .onDisappear {
            appState.reviewWindowTarget = nil
        }
    }

    // MARK: - Content Pane (left, ~65% width)

    private func contentPane(
        project: Project,
        delegation: RuntimeDelegationState,
        review: RuntimeDelegationReview,
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(project.name)
                        .font(.title2.weight(.semibold).monospaced())
                        .foregroundColor(.white)

                    HStack(spacing: 8) {
                        Text("Delegation Review")
                            .font(.caption.weight(.bold))
                            .tracking(2)
                            .foregroundColor(.orange.opacity(0.85))

                        if milestoneNumber > 1 {
                            Text("Revision \(milestoneNumber)")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.5))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.08)),
                                )
                        }
                    }
                }

                // Summary
                if let summary = manifest?.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Metadata
                HStack(spacing: 16) {
                    metadataItem(
                        label: "Milestone",
                        value: review.milestoneId,
                    )
                    if let artifacts = manifest?.artifacts {
                        metadataItem(
                            label: "Artifacts",
                            value: "\(artifacts.count)",
                        )
                    }
                    metadataItem(
                        label: "Worker",
                        value: String(delegation.workerId.prefix(8)),
                    )
                }
                .font(.caption.monospaced())
                .foregroundColor(.white.opacity(0.42))

                // Swift changes banner
                if manifest?.swiftChanges == true, !swiftChangesBannerDismissed {
                    HStack(spacing: 10) {
                        Image(systemName: "info.circle.fill")
                            .font(.callout)
                            .foregroundColor(.blue.opacity(0.7))

                        Text("This milestone includes Swift changes. The running app reflects the previous build.")
                            .font(.callout)
                            .foregroundColor(.white.opacity(0.72))

                        Spacer()

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("./scripts/dev/restart-alpha-stable.sh", forType: .string)
                        }) {
                            Text("Copy rebuild cmd")
                                .font(.caption.weight(.medium))
                                .foregroundColor(.blue.opacity(0.8))
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                swiftChangesBannerDismissed = true
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.blue.opacity(0.08))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.blue.opacity(0.2), lineWidth: 1),
                            ),
                    )
                }

                Divider()
                    .background(Color.white.opacity(0.08))

                // Brief
                VStack(alignment: .leading, spacing: 10) {
                    sectionLabel("REVIEW BRIEF")

                    Text(reviewBrief.isEmpty ? "No review brief was found yet." : reviewBrief)
                        .font(.body)
                        .foregroundColor(.white.opacity(0.78))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                // Artifacts
                if let artifacts = manifest?.artifacts, !artifacts.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("ARTIFACTS")

                        ForEach(artifacts) { artifact in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.35))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artifact.label)
                                        .font(.callout.weight(.medium))
                                        .foregroundColor(.white.opacity(0.88))
                                    Text(artifact.path)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.white.opacity(0.35))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                // Changes diff
                if !diffStat.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("CHANGES")

                        Text(diffStat)
                            .font(.caption.monospaced())
                            .foregroundColor(.white.opacity(0.62))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)

                        if !fullDiff.isEmpty {
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showFullDiff.toggle()
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: showFullDiff ? "chevron.down" : "chevron.right")
                                        .font(.caption2)
                                    Text(showFullDiff ? "Hide Full Diff" : "Show Full Diff")
                                        .font(.caption.weight(.medium))
                                }
                                .foregroundColor(.white.opacity(0.5))
                            }
                            .buttonStyle(.plain)

                            if showFullDiff {
                                ScrollView(.horizontal, showsIndicators: true) {
                                    Text(fullDiff)
                                        .font(.caption.monospaced())
                                        .foregroundColor(.white.opacity(0.62))
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 400)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.black.opacity(0.25)),
                                )
                            }
                        }
                    }
                }

                // Previous round context
                if let previousDecision {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("PREVIOUS ROUND")

                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: previousDecision.decision == "approve" ? "checkmark.circle" : "arrow.triangle.2.circlepath")
                                    .font(.caption)
                                    .foregroundColor(previousDecision.decision == "approve" ? .green.opacity(0.7) : .orange.opacity(0.7))

                                Text("Decision: \(previousDecision.decision)")
                                    .font(.callout.weight(.medium))
                                    .foregroundColor(.white.opacity(0.72))
                            }

                            if let note = previousDecision.note, !note.isEmpty {
                                Text(note)
                                    .font(.body)
                                    .foregroundColor(.white.opacity(0.62))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.04)),
                        )
                    }
                }
            }
            .padding(24)
        }
    }

    // MARK: - Decision Rail (right, ~35% width)

    private func decisionRail(
        project: Project,
        delegation: RuntimeDelegationState,
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Decision")
                .font(.headline)
                .foregroundColor(.white.opacity(0.72))

            decisionCard(
                option: .approve,
                title: manifest?.decisions?.approve?.label ?? "Approve",
                description: manifest?.decisions?.approve?.description ?? "Ship this milestone and move on.",
                icon: "checkmark.circle.fill",
                accentColor: .green,
            )

            decisionCard(
                option: .requestChanges,
                title: manifest?.decisions?.requestChanges?.label ?? "Request Changes",
                description: manifest?.decisions?.requestChanges?.description ?? "Worker will address your feedback and submit a new revision.",
                icon: "arrow.triangle.2.circlepath",
                accentColor: .orange,
            )

            decisionCard(
                option: .writeResponse,
                title: "Write a Response",
                description: "Provide custom instructions to the worker.",
                icon: "text.bubble",
                accentColor: .blue,
            )

            if selectedDecision == .requestChanges || selectedDecision == .writeResponse {
                TextEditor(text: $note)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 100)
                    .accessibilityIdentifier(AccessibilityIdentifiers.delegationReviewNotesIdentifier)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.white.opacity(0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1),
                            ),
                    )
            }

            Spacer()

            if let selectedDecision {
                Button(action: {
                    let decision: DelegationLoopManager.ReviewDecision = selectedDecision == .approve
                        ? .approve
                        : .requestChanges
                    appState.submitDelegationReview(
                        for: project,
                        delegation: delegation,
                        decision: decision,
                        note: note,
                        fromWindow: true,
                    )
                }) {
                    Text("Submit Decision")
                        .font(.body.weight(.semibold))
                        .foregroundColor(selectedDecision == .approve ? .black : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selectedDecision == .approve ? Color.white.opacity(0.92) : Color.orange.opacity(0.65)),
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(
                    selectedDecision == .approve
                        ? AccessibilityIdentifiers.delegationReviewApproveIdentifier
                        : AccessibilityIdentifiers.delegationReviewRequestChangesIdentifier,
                )
            }
        }
        .padding(20)
        .background(Color.black.opacity(0.15))
    }

    // MARK: - Decision Card

    private func decisionCard(
        option: DecisionOption,
        title: String,
        description: String,
        icon: String,
        accentColor: Color,
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedDecision = option
                }
            }) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(selectedDecision == option ? accentColor : .white.opacity(0.4))

                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white.opacity(0.92))

                    Spacer()
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(selectedDecision == option ? accentColor.opacity(0.12) : Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(
                                    selectedDecision == option ? accentColor.opacity(0.4) : Color.white.opacity(0.06),
                                    lineWidth: 1,
                                ),
                        ),
                )
            }
            .buttonStyle(.plain)

            Text(description)
                .font(.caption)
                .foregroundColor(.white.opacity(0.45))
                .padding(.horizontal, 4)
        }
    }

    // MARK: - Helpers

    private func metadataItem(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label + ":")
                .foregroundColor(.white.opacity(0.35))
            Text(value)
                .foregroundColor(.white.opacity(0.55))
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.orange.opacity(0.6))
                .frame(width: 4, height: 4)

            Text(title)
                .font(.caption.weight(.bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.45))
        }
    }

    // MARK: - Data Loading

    private func loadReviewArtifacts() async {
        guard let currentReview else {
            await MainActor.run {
                reviewBrief = ""
                manifest = nil
                previousDecision = nil
                diffStat = ""
                fullDiff = ""
                showFullDiff = false
                swiftChangesBannerDismissed = false
            }
            return
        }

        let brief = (try? String(contentsOfFile: currentReview.briefPath, encoding: .utf8)) ?? ""
        let manifestData = try? Data(contentsOf: URL(fileURLWithPath: currentReview.manifestPath))
        let decodedManifest = manifestData.flatMap {
            try? JSONDecoder().decode(DelegationReviewManifest.self, from: $0)
        }

        // Load previous round context
        let prevDecision = loadPreviousRoundDecision(currentMilestoneId: currentReview.milestoneId)

        // Load worktree diff
        let worktreePath = delegation?.worktreePath
        let stat = worktreePath.flatMap { Self.runGitDiff(in: $0, stat: true) } ?? ""
        let diff = worktreePath.flatMap { Self.runGitDiff(in: $0, stat: false) } ?? ""

        await MainActor.run {
            reviewBrief = brief
            manifest = decodedManifest
            previousDecision = prevDecision
            diffStat = stat
            fullDiff = diff
            showFullDiff = false
            swiftChangesBannerDismissed = false
        }
    }

    private static func runGitDiff(in worktreePath: String, stat: Bool) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var arguments = ["diff", "HEAD"]
        if stat {
            arguments.append("--stat")
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: worktreePath)
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return output?.isEmpty == true ? nil : output
    }

    private func loadPreviousRoundDecision(currentMilestoneId: String) -> PreviousRoundDecision? {
        guard let currentNum = Int(currentMilestoneId), currentNum > 1 else { return nil }
        let previousId = String(format: "%02d", currentNum - 1)

        guard let currentReview,
              let manifestPath = URL(string: currentReview.manifestPath)?.deletingLastPathComponent().deletingLastPathComponent()
        else { return nil }

        let previousDecisionPath = manifestPath
            .appendingPathComponent(previousId, isDirectory: true)
            .appendingPathComponent("decision.json")

        guard let data = try? Data(contentsOf: previousDecisionPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        return PreviousRoundDecision(
            decision: json["decision"] as? String ?? "unknown",
            note: json["note"] as? String,
        )
    }
}

// MARK: - Supporting Types

private enum DecisionOption {
    case approve
    case requestChanges
    case writeResponse
}

private struct PreviousRoundDecision {
    let decision: String
    let note: String?
}

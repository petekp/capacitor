import SwiftUI

struct DelegationReviewWindow: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var reviewBrief = ""
    @State private var manifest: DelegationReviewManifest?
    @State private var previousDecision: PreviousRoundDecision?
    @State private var selectedDecision: DecisionOption?
    @State private var note = ""

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
                title: "Approve",
                description: "Ship this milestone and move on.",
                icon: "checkmark.circle.fill",
                accentColor: .green,
            )

            decisionCard(
                option: .requestChanges,
                title: "Request Changes",
                description: "Worker will address your feedback and submit a new revision.",
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
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedDecision = option
            }
        }) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(selectedDecision == option ? accentColor : .white.opacity(0.4))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundColor(.white.opacity(0.92))
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                }

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

        await MainActor.run {
            reviewBrief = brief
            manifest = decodedManifest
            previousDecision = prevDecision
        }
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

import SwiftUI

struct DelegationReviewView: View {
    @Environment(AppState.self) var appState: AppState
    @Environment(\.floatingMode) private var floatingMode

    let project: Project

    @State private var reviewBrief = ""
    @State private var manifest: DelegationReviewManifest?
    @State private var note = ""
    @State private var appeared = false

    private var delegation: RuntimeDelegationState? {
        appState.delegationState(for: project)
    }

    private var currentReview: RuntimeDelegationReview? {
        delegation?.currentReview
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    BackButton(title: "Projects") {
                        appState.showProjectList()
                    }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text(project.name)
                        .font(AppTypography.pageTitle.monospaced())
                        .foregroundColor(.white)

                    Text("Delegation Review")
                        .font(AppTypography.label.weight(.bold))
                        .tracking(2)
                        .foregroundColor(.orange.opacity(0.85))
                }
                .opacity(appeared ? 1 : 0)
                .offset(y: appeared ? 0 : 8)

                if let delegation, let currentReview {
                    reviewSummary(delegation: delegation, review: currentReview)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 10)

                    reviewBriefSection
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 12)

                    artifactSection
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 14)

                    notesSection
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)

                    actionRow(delegation: delegation)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 18)
                } else {
                    Text("The active review is no longer available.")
                        .font(AppTypography.body)
                        .foregroundColor(.white.opacity(0.65))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, floatingMode ? 12 : 16)
            .padding(.bottom, floatingMode ? 64 : 16)
        }
        .accessibilityIdentifier(AccessibilityIdentifiers.delegationReviewIdentifier)
        .background(floatingMode ? Color.clear : Color.hudBackground)
        .task(id: currentReview?.manifestPath ?? "no-review") {
            await loadReviewArtifacts()
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82).delay(0.08)) {
                appeared = true
            }
        }
        .onExitCommand {
            appState.showProjectList()
        }
    }

    private func reviewSummary(
        delegation: RuntimeDelegationState,
        review: RuntimeDelegationReview,
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let summary = manifest?.summary, !summary.isEmpty {
                Text(summary)
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.78))
            } else {
                Text("Milestone \(review.milestoneId) is ready for a human decision.")
                    .font(AppTypography.body)
                    .foregroundColor(.white.opacity(0.78))
            }

            Text("Worker \(delegation.workerId.prefix(8)) • Session \(delegation.sessionId ?? "pending")")
                .font(AppTypography.label)
                .foregroundColor(.white.opacity(0.42))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reviewBriefSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionLabel(title: "REVIEW BRIEF")

            Text(reviewBrief.isEmpty ? "No review brief was found yet." : reviewBrief)
                .font(AppTypography.body)
                .foregroundColor(.white.opacity(0.78))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private var artifactSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionLabel(title: "ARTIFACTS")

            if let artifacts = manifest?.artifacts, !artifacts.isEmpty {
                ForEach(artifacts) { artifact in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.label)
                            .font(AppTypography.bodySecondary.weight(.medium))
                            .foregroundColor(.white.opacity(0.88))
                        Text(artifact.path)
                            .font(AppTypography.captionSmall.monospaced())
                            .foregroundColor(.white.opacity(0.42))
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let currentReview {
                Text(currentReview.manifestPath)
                    .font(AppTypography.captionSmall.monospaced())
                    .foregroundColor(.white.opacity(0.42))
                    .textSelection(.enabled)
            } else {
                Text("No manifest data is available.")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.55))
            }
        }
    }

    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            DetailSectionLabel(title: "NOTES TO WORKER")

            TextEditor(text: $note)
                .font(AppTypography.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 140)
                .accessibilityIdentifier(AccessibilityIdentifiers.delegationReviewNotesIdentifier)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1),
                        ),
                )
        }
    }

    private func actionRow(delegation: RuntimeDelegationState) -> some View {
        HStack(spacing: 12) {
            Button(action: {
                _Concurrency.Task { @MainActor in
                    try? await appState.submitDelegationReview(
                        for: project,
                        delegation: delegation,
                        decision: .requestChanges,
                        note: note,
                    )
                }
            }) {
                Text("Request Changes")
                    .font(AppTypography.bodySecondary.weight(.semibold))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityIdentifiers.delegationReviewRequestChangesIdentifier)

            Button(action: {
                _Concurrency.Task { @MainActor in
                    try? await appState.submitDelegationReview(
                        for: project,
                        delegation: delegation,
                        decision: .approve,
                        note: note,
                    )
                }
            }) {
                Text("Approve")
                    .font(AppTypography.bodySecondary.weight(.semibold))
                    .foregroundColor(.black.opacity(0.92))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityIdentifiers.delegationReviewApproveIdentifier)

            Spacer()
        }
    }

    private func loadReviewArtifacts() async {
        guard let currentReview else {
            await MainActor.run {
                reviewBrief = ""
                manifest = nil
            }
            return
        }

        let brief = (try? String(contentsOfFile: currentReview.briefPath, encoding: .utf8)) ?? ""
        let manifestData = try? Data(contentsOf: URL(fileURLWithPath: currentReview.manifestPath))
        let decodedManifest = manifestData.flatMap {
            try? JSONDecoder().decode(DelegationReviewManifest.self, from: $0)
        }

        await MainActor.run {
            reviewBrief = brief
            manifest = decodedManifest
        }
    }
}

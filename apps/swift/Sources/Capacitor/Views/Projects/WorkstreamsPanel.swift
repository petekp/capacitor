import SwiftUI

struct WorkstreamsPanel: View {
    let project: Project
    @ObservedObject var manager: WorkstreamsManager

    private var state: WorkstreamsManager.State {
        manager.state(for: project)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                DetailSectionLabel(title: "WORKSTREAMS")
                Spacer()
                Button(action: { manager.create(for: project) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text(state.isCreating ? "Creating..." : "New Workstream")
                    }
                    .font(AppTypography.bodySecondary.weight(.medium))
                    .foregroundColor(.white.opacity(0.9))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.white.opacity(0.08)),
                    )
                }
                .buttonStyle(.plain)
                .disabled(state.isCreating || state.isLoading)
            }

            if state.isLoading {
                Text("Loading workstreams...")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.6))
            } else if state.worktrees.isEmpty {
                Text("No workstreams yet.")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.white.opacity(0.5))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(state.worktrees, id: \.path) { worktree in
                        worktreeRow(worktree)
                    }
                }
            }

            if let errorMessage = state.errorMessage {
                Text(errorMessage)
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.red.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: project.path) {
            manager.load(for: project)
        }
    }

    private func worktreeRow(_ worktree: WorktreeService.Worktree) -> some View {
        let isDestroying = state.destroyingNames.contains(worktree.name)
        let isForceDestroyable = state.forceDestroyableNames.contains(worktree.name)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(worktree.name)
                        .font(AppTypography.body.weight(.semibold))
                        .foregroundColor(.white.opacity(0.9))

                    if let branchRef = worktree.branchRef {
                        Text(branchName(from: branchRef))
                            .font(AppTypography.bodySecondary)
                            .foregroundColor(.white.opacity(0.55))
                    }
                }

                Spacer()

                Button("Open") {
                    manager.open(worktree)
                }
                .buttonStyle(.plain)
                .font(AppTypography.bodySecondary.weight(.medium))
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(0.06)),
                )
                .disabled(isDestroying)

                if isForceDestroyable {
                    Button(isDestroying ? "Destroying..." : "Force Destroy") {
                        manager.destroy(worktreeName: worktree.name, for: project, force: true)
                    }
                    .buttonStyle(.plain)
                    .font(AppTypography.bodySecondary.weight(.medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.18)),
                    )
                    .disabled(isDestroying)
                } else {
                    Button(isDestroying ? "Destroying..." : "Destroy") {
                        manager.destroy(worktreeName: worktree.name, for: project)
                    }
                    .buttonStyle(.plain)
                    .font(AppTypography.bodySecondary.weight(.medium))
                    .foregroundColor(.red.opacity(0.85))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.red.opacity(0.12)),
                    )
                    .disabled(isDestroying)
                }
            }

            if isForceDestroyable {
                Text("Session active — force destroy will remove regardless")
                    .font(AppTypography.bodySecondary)
                    .foregroundColor(.orange.opacity(0.85))
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.03)),
        )
    }

    private func branchName(from branchRef: String) -> String {
        let prefix = "refs/heads/"
        if branchRef.hasPrefix(prefix) {
            return String(branchRef.dropFirst(prefix.count))
        }
        return branchRef
    }
}

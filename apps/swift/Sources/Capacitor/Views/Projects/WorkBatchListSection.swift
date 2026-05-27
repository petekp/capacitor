import SwiftUI

struct WorkBatchListSection: View {
    let batches: [WorkBatchProjection]
    let checkpointFocusTarget: WorkBatchCheckpointFocusTarget?
    let onOpen: (WorkBatchProjection) -> Void
    let onOpenCockpit: (WorkBatchProjection) -> Void
    let onUnresolve: (WorkBatchProjection, WorkBatchTaskRecord) -> Void
    let onCheckpointResponse: (WorkBatchProjection, WorkBatchCheckpointRecord, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DetailSectionLabel(
                title: "WORK BATCHES",
                count: batches.reduce(0) { $0 + $1.queuedTaskCount },
                countAccessibilityLabel: "\(batches.reduce(0) { $0 + $1.queuedTaskCount }) queued tasks",
            )

            if batches.isEmpty {
                Text("No active batches")
                    .font(AppTypography.bodySecondary)
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(batches) { batch in
                        WorkBatchRow(
                            batch: batch,
                            checkpointFocusTarget: checkpointFocusTarget,
                            onOpen: { onOpen(batch) },
                            onOpenCockpit: { onOpenCockpit(batch) },
                            onUnresolve: { task in
                                onUnresolve(batch, task)
                            },
                            onCheckpointResponse: { checkpoint, response in
                                onCheckpointResponse(batch, checkpoint, response)
                            },
                        )
                    }
                }
            }
        }
    }
}

private struct WorkBatchRow: View {
    let batch: WorkBatchProjection
    let checkpointFocusTarget: WorkBatchCheckpointFocusTarget?
    let onOpen: () -> Void
    let onOpenCockpit: () -> Void
    let onUnresolve: (WorkBatchTaskRecord) -> Void
    let onCheckpointResponse: (WorkBatchCheckpointRecord, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: onOpen) {
                    summaryContent
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())

                Button(action: onOpenCockpit) {
                    terminalIcon
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open Claude Code session")
            }

            if !batch.pendingCheckpoints.isEmpty {
                VStack(spacing: 6) {
                    ForEach(batch.pendingCheckpoints) { checkpoint in
                        WorkBatchCheckpointCard(
                            checkpoint: checkpoint,
                            focusTarget: checkpointFocusTarget?.batchID == batch.id ? checkpointFocusTarget : nil,
                            onSubmit: { response in
                                onCheckpointResponse(checkpoint, response)
                            },
                        )
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                ForEach(batch.tasks.prefix(4)) { task in
                    WorkBatchTaskRow(task: task, onUnresolve: { onUnresolve(task) })
                }
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.white.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(batch.name), \(batch.status.label), \(batch.queuedTaskCount) queued tasks")
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                StatusChip(state: batch.status.sessionState, style: .compact)

                Text(batch.name)
                    .font(AppTypography.cardTitle)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(batch.queuedTaskCount)")
                    .font(AppTypography.badge)
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
                    .frame(minWidth: 18)
            }

            Text(batch.currentActivitySummary)
                .font(AppTypography.bodySecondary)
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var terminalIcon: some View {
        Image(systemName: "terminal")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.72))
            .frame(width: 24, height: 24)
    }
}

private struct WorkBatchCheckpointCard: View {
    let checkpoint: WorkBatchCheckpointRecord
    let focusTarget: WorkBatchCheckpointFocusTarget?
    let onSubmit: (String) -> Void

    @State private var response = ""
    @FocusState private var isAnswerFocused: Bool

    private var trimmedResponse: String {
        response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var focusRequestID: UUID? {
        guard focusTarget?.checkpointID == checkpoint.id else { return nil }
        return focusTarget?.requestID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.85))
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 4) {
                    Text(checkpoint.question)
                        .font(AppTypography.bodySecondary.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)

                    let reason = checkpoint.reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !reason.isEmpty {
                        Text(reason)
                            .font(AppTypography.caption)
                            .foregroundStyle(.white.opacity(0.58))
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    let recommendedAction = checkpoint.recommendedAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !recommendedAction.isEmpty {
                        Text("Recommended: \(recommendedAction)")
                            .font(AppTypography.caption.weight(.semibold))
                            .foregroundStyle(.orange.opacity(0.82))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            HStack(alignment: .center, spacing: 8) {
                TextField("Answer", text: $response, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(AppTypography.bodySecondary)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(1 ... 3)
                    .focused($isAnswerFocused)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.07))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button(action: {
                    onSubmit(trimmedResponse)
                    response = ""
                }) {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(trimmedResponse.isEmpty ? .white.opacity(0.25) : .white.opacity(0.82))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .disabled(trimmedResponse.isEmpty)
                .accessibilityLabel("Answer checkpoint")
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.22), lineWidth: 1),
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: focusRequestID) {
            guard focusRequestID != nil else { return }
            await _Concurrency.Task.yield()
            isAnswerFocused = true
        }
    }
}

private struct WorkBatchTaskRow: View {
    let task: WorkBatchTaskRecord
    let onUnresolve: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(task.status.dotColor)
                .frame(width: 5, height: 5)

            Text(task.displayTitle)
                .font(AppTypography.bodySecondary)
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(1)

            Spacer(minLength: 8)

            if task.status == .done {
                Button(action: onUnresolve) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Unresolve \(task.displayTitle)")
            }
        }
    }
}

private extension WorkBatchTaskStatus {
    var dotColor: Color {
        switch self {
        case .queued:
            .white.opacity(0.45)
        case .working:
            .blue.opacity(0.85)
        case .needsYou:
            .orange.opacity(0.9)
        case .done:
            .green.opacity(0.75)
        }
    }
}

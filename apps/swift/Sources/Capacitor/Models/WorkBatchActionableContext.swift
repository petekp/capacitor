import CryptoKit
import Foundation

enum WorkBatchActionableContext {
    static func digest(
        batchID: String,
        tasks: [WorkBatchTaskItem],
        checkpoints: [WorkBatchCheckpointRecord],
    ) -> String? {
        let queuedTasks = tasks
            .filter { $0.status == WorkBatchTaskStatus.queued.rawValue }
            .sorted { lhs, rhs in
                if lhs.id != rhs.id {
                    return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        let queuedTaskIDs = Set(queuedTasks.map(\.id))
        let answeredCheckpoints = checkpoints
            .filter {
                $0.batchID == batchID &&
                    $0.status == .answered &&
                    queuedTaskIDs.contains($0.taskID)
            }
            .sorted { lhs, rhs in
                lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }

        guard !queuedTasks.isEmpty || !answeredCheckpoints.isEmpty else {
            return nil
        }

        var lines = [
            "work-batch-actionable-context@v1",
            "batch:\(stable(batchID))",
        ]
        for task in queuedTasks {
            lines.append("task:\(stable(task.id))")
            lines.append("title:\(stable(task.title))")
            lines.append("body:\(stable(task.body))")
            lines.append("status:\(stable(task.status))")
        }
        for checkpoint in answeredCheckpoints {
            lines.append("checkpoint:\(stable(checkpoint.id))")
            lines.append("checkpoint-task:\(stable(checkpoint.taskID))")
            lines.append("checkpoint-question:\(stable(checkpoint.question))")
            lines.append("checkpoint-response:\(stable(checkpoint.response ?? ""))")
        }

        return sha256Hex(lines.joined(separator: "\n"))
    }

    static func deliveryPrompt(
        batchID _: String,
        tasks: [WorkBatchTaskRecord],
        preferredTaskID: String?,
    ) -> String? {
        let queuedTasks = tasks
            .filter { $0.status == .queued }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
        guard !queuedTasks.isEmpty else {
            return nil
        }

        let selectedTask = preferredTaskID
            .flatMap { preferredID in queuedTasks.first { $0.id == preferredID } }
            ?? queuedTasks.first
        guard let selectedTask else {
            return nil
        }

        if preferredTaskID != nil || queuedTasks.count == 1 {
            return "New task queued: \(sentenceFragment(selectedTask.displayTitle))"
        }
        return "\(queuedTasks.count) tasks queued. Starting with \(sentenceFragment(selectedTask.displayTitle))"
    }

    private static func sentenceFragment(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Task."
        }
        if let last = trimmed.last,
           [".", "!", "?"].contains(last)
        {
            return trimmed
        }
        return "\(trimmed)."
    }

    private static func stable(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

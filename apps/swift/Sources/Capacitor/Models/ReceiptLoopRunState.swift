import Foundation

struct ReceiptLoopRunState: Identifiable, Equatable {
    enum Status: String, Equatable {
        case running
        case completed
        case failed
    }

    static let expectedNextSignal = "receipt"
    static let healthySilenceWindow = "~20m"

    let id: String
    let projectPath: String
    let ideaId: String?
    let ideaTitle: String
    let status: Status
    let failureReason: String?
    let createdAt: String
    let updatedAt: String

    init(
        id: String,
        projectPath: String,
        ideaId: String?,
        ideaTitle: String,
        status: Status,
        failureReason: String? = nil,
        createdAt: String,
        updatedAt: String,
    ) {
        self.id = id
        self.projectPath = projectPath
        self.ideaId = ideaId
        self.ideaTitle = ideaTitle
        self.status = status
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var attentionReason: String {
        switch status {
        case .running:
            runningCommitment
        case .completed:
            "Receipt captured for \(ideaTitle)"
        case .failed:
            cleaned(failureReason) ?? "Claude receipt loop failed"
        }
    }

    var runningCommitment: String {
        "Working on: \(ideaTitle). Expected next signal: \(Self.expectedNextSignal). Healthy silence window: \(Self.healthySilenceWindow)"
    }

    func runtimeRunState(updatedAtOverride: String? = nil) -> RuntimeRunState {
        RuntimeRunState(
            id: id,
            projectPath: projectPath,
            methodId: CircuitReceiptGoalPacketMethod.id,
            methodName: CircuitReceiptGoalPacketMethod.template.name,
            status: runtimeStatus,
            sessionId: nil,
            delegationWorkerId: nil,
            statusMessage: attentionReason,
            createdAt: createdAt,
            updatedAt: updatedAtOverride ?? updatedAt,
            activeCheckpoint: nil,
            ideaId: ideaId,
            ideaTitle: ideaTitle,
            ideaDescription: nil,
        )
    }

    private var runtimeStatus: String {
        switch status {
        case .running:
            "active"
        case .completed:
            "completed"
        case .failed:
            "failed"
        }
    }

    private func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else {
            return nil
        }
        return trimmed
    }
}

struct ReceiptLoopRunStart: Equatable {
    let state: ReceiptLoopRunState
    let didStart: Bool
}

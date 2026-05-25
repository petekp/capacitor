import Foundation

enum CircuitReceiptGoalPacketMethod {
    static let id = "claude_receipt_goal_packet"

    static let template = MethodTemplate(
        id: id,
        name: "Claude Receipt Goal Packet",
        description: "Start a bounded Claude Code run from this idea and capture a receipt.",
        taskArchetype: "receipt",
        defaultInvolvement: .supervised,
        phases: [
            PhaseTemplate(
                id: "receipt-goal-packet",
                name: "Receipt Goal Packet",
                checkpointPolicy: "receipt",
                skillHint: nil,
            ),
        ],
    )

    static func isReceiptGoalPacket(_ method: MethodTemplate) -> Bool {
        method.id == id
    }

    static func includingReceiptGoalPacket(_ methods: [MethodTemplate]) -> [MethodTemplate] {
        guard !methods.contains(where: isReceiptGoalPacket) else {
            return methods
        }
        return methods + [template]
    }
}

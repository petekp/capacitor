/// Formats a run's phase progression into a display string for project cards.
///
/// Format: "N/M PhaseName" where N is 1-based current index, M is total phases.
/// Falls back to `statusMessage` when phases are empty (non-method-run sessions).
enum PhaseStepFormatter {
    static func format(
        phases: [RuntimePhaseInstance],
        currentPhaseIndex: Int,
        runStatus: String,
        statusMessage: String?,
    ) -> String? {
        guard !phases.isEmpty else { return statusMessage }

        let total = phases.count
        let clampedIndex = min(max(currentPhaseIndex, 0), total - 1)

        switch runStatus {
        case "completed":
            return "\(total)/\(total) Complete"
        case "failed":
            let phaseName = phases[clampedIndex].name
            return "\(clampedIndex + 1)/\(total) Failed at \(phaseName)"
        case "cancelled":
            return "\(clampedIndex + 1)/\(total) Cancelled"
        default:
            let phaseName = phases[clampedIndex].name
            return "\(clampedIndex + 1)/\(total) \(phaseName)"
        }
    }
}

import Foundation

struct DelegationReviewManifest: Decodable {
    struct Artifact: Decodable, Identifiable {
        let label: String
        let path: String

        var id: String {
            "\(label)|\(path)"
        }
    }

    struct DecisionHint: Decodable {
        let label: String
        let description: String
    }

    struct DecisionHints: Decodable {
        let approve: DecisionHint?
        let requestChanges: DecisionHint?

        enum CodingKeys: String, CodingKey {
            case approve
            case requestChanges = "request_changes"
        }
    }

    let version: Int
    let milestoneId: String
    let summary: String?
    let artifacts: [Artifact]
    let decisions: DecisionHints?
    let swiftChanges: Bool?

    enum CodingKeys: String, CodingKey {
        case version
        case milestoneId = "milestone_id"
        case summary
        case artifacts
        case decisions
        case swiftChanges = "swift_changes"
    }
}

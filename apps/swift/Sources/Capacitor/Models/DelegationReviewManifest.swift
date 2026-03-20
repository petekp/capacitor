import Foundation

struct DelegationReviewManifest: Decodable {
    struct Artifact: Decodable, Identifiable {
        let label: String
        let path: String

        var id: String {
            "\(label)|\(path)"
        }
    }

    let version: Int
    let milestoneId: String
    let summary: String?
    let artifacts: [Artifact]

    enum CodingKeys: String, CodingKey {
        case version
        case milestoneId = "milestone_id"
        case summary
        case artifacts
    }
}

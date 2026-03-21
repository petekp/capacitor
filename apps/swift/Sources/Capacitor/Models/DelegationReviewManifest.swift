import Foundation

struct DelegationReviewManifest: Decodable {
    enum ArtifactType: String, Decodable {
        case text
        case screenshot
        case recording
        case mermaid
    }

    struct Artifact: Decodable, Identifiable {
        let label: String
        let path: String
        let artifactType: ArtifactType?
        let width: Int?
        let height: Int?
        let durationSecs: Double?

        var id: String {
            "\(label)|\(path)"
        }

        var isMedia: Bool {
            switch artifactType {
            case .screenshot, .recording, .mermaid: true
            default: false
            }
        }

        enum CodingKeys: String, CodingKey {
            case label, path
            case artifactType = "artifact_type"
            case width, height
            case durationSecs = "duration_secs"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            label = try container.decode(String.self, forKey: .label)
            path = try container.decode(String.self, forKey: .path)
            artifactType = try container.decodeIfPresent(ArtifactType.self, forKey: .artifactType)
            width = try container.decodeIfPresent(Int.self, forKey: .width)
            height = try container.decodeIfPresent(Int.self, forKey: .height)
            durationSecs = try container.decodeIfPresent(Double.self, forKey: .durationSecs)
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

import Foundation

extension ProjectCreation: Identifiable {}

extension ProjectCreation: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, name, path, description, status
        case sessionId = "session_id"
        case progress, error
        case createdAt = "created_at"
        case completedAt = "completed_at"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let name = try container.decode(String.self, forKey: .name)
        let path = try container.decode(String.self, forKey: .path)
        let description = try container.decode(String.self, forKey: .description)
        let status = try container.decode(CreationStatus.self, forKey: .status)
        let sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
        let progress = try container.decodeIfPresent(CreationProgress.self, forKey: .progress)
        let error = try container.decodeIfPresent(String.self, forKey: .error)
        let createdAt = try container.decode(String.self, forKey: .createdAt)
        let completedAt = try container.decodeIfPresent(String.self, forKey: .completedAt)

        self.init(
            id: id,
            name: name,
            path: path,
            description: description,
            status: status,
            sessionId: sessionId,
            progress: progress,
            error: error,
            createdAt: createdAt,
            completedAt: completedAt
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(path, forKey: .path)
        try container.encode(description, forKey: .description)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(sessionId, forKey: .sessionId)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(completedAt, forKey: .completedAt)
    }
}

extension CreationStatus: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "pending": self = .pending
        case "in_progress", "inProgress": self = .inProgress
        case "completed": self = .completed
        case "failed": self = .failed
        case "cancelled": self = .cancelled
        default: self = .pending
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .pending: try container.encode("pending")
        case .inProgress: try container.encode("in_progress")
        case .completed: try container.encode("completed")
        case .failed: try container.encode("failed")
        case .cancelled: try container.encode("cancelled")
        }
    }
}

extension CreationProgress: Codable {
    private enum CodingKeys: String, CodingKey {
        case phase, message
        case percentComplete = "percent_complete"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let phase = try container.decode(String.self, forKey: .phase)
        let message = try container.decode(String.self, forKey: .message)
        let percentComplete = try container.decodeIfPresent(UInt8.self, forKey: .percentComplete)

        self.init(phase: phase, message: message, percentComplete: percentComplete)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encode(message, forKey: .message)
        try container.encodeIfPresent(percentComplete, forKey: .percentComplete)
    }
}

extension ProjectCreation {
    var createdAtDate: Date? {
        ISO8601DateFormatter().date(from: createdAt)
    }

    var completedAtDate: Date? {
        completedAt.flatMap { ISO8601DateFormatter().date(from: $0) }
    }
}

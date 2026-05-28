import Foundation

/// Single boundary decode for the canonical runtime status enums.
///
/// Rust owns these enums (`run_types.rs`, `domain/types.rs`) and serializes them
/// with `#[serde(rename_all = "snake_case")]`. The UniFFI bridge mirrors them as
/// `RunStatus`, `DelegationStatus`, `RoutingStatus`, `SessionState`, and
/// `PhaseStatus`. Rather than re-parse the wire strings in dozens of if-ladders,
/// we decode each status string into its typed enum exactly once at the
/// `RuntimeClient.map*` boundary, then switch exhaustively everywhere downstream.
///
/// A genuinely-unknown status is a contract violation and is surfaced as a
/// `RuntimeStatusDecodeError`. The error joins the existing throwing
/// snapshot-decode path so an unrecognized status degrades exactly like a
/// malformed-JSON snapshot (logged + retried), instead of being silently
/// coerced into a lossy default such as `.idle` or `.pending`.
struct RuntimeStatusDecodeError: Error, CustomStringConvertible {
    let kind: String
    let rawValue: String

    var description: String {
        "Unknown \(kind) wire value: \(rawValue)"
    }
}

extension RunStatus {
    /// Decodes the canonical snake_case wire spelling into the typed enum.
    /// Throws `RuntimeStatusDecodeError` for any unrecognized value.
    static func decode(wire raw: String) throws -> RunStatus {
        switch raw {
        case "created": .created
        case "active": .active
        case "paused": .paused
        case "completed": .completed
        case "failed": .failed
        case "cancelled": .cancelled
        default: throw RuntimeStatusDecodeError(kind: "RunStatus", rawValue: raw)
        }
    }

    /// Canonical snake_case wire spelling (mirrors the Rust serde representation).
    var wireValue: String {
        switch self {
        case .created: "created"
        case .active: "active"
        case .paused: "paused"
        case .completed: "completed"
        case .failed: "failed"
        case .cancelled: "cancelled"
        }
    }

    /// Terminal states mirror `RunStatus::is_terminal` in Rust.
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: true
        case .created, .active, .paused: false
        }
    }
}

extension DelegationStatus {
    static func decode(wire raw: String) throws -> DelegationStatus {
        switch raw {
        case "working": .working
        case "review_needed": .reviewNeeded
        case "resume_pending": .resumePending
        case "resume_failed": .resumeFailed
        default: throw RuntimeStatusDecodeError(kind: "DelegationStatus", rawValue: raw)
        }
    }

    var wireValue: String {
        switch self {
        case .working: "working"
        case .reviewNeeded: "review_needed"
        case .resumePending: "resume_pending"
        case .resumeFailed: "resume_failed"
        }
    }
}

extension RoutingStatus {
    static func decode(wire raw: String) throws -> RoutingStatus {
        switch raw {
        case "attached": .attached
        case "detached": .detached
        case "unavailable": .unavailable
        default: throw RuntimeStatusDecodeError(kind: "RoutingStatus", rawValue: raw)
        }
    }

    var wireValue: String {
        switch self {
        case .attached: "attached"
        case .detached: "detached"
        case .unavailable: "unavailable"
        }
    }
}

extension SessionState {
    static func decode(wire raw: String) throws -> SessionState {
        switch raw {
        case "working": .working
        case "ready": .ready
        case "idle": .idle
        case "compacting": .compacting
        case "waiting": .waiting
        default: throw RuntimeStatusDecodeError(kind: "SessionState", rawValue: raw)
        }
    }

    var wireValue: String {
        switch self {
        case .working: "working"
        case .ready: "ready"
        case .idle: "idle"
        case .compacting: "compacting"
        case .waiting: "waiting"
        }
    }
}

extension PhaseStatus {
    static func decode(wire raw: String) throws -> PhaseStatus {
        switch raw {
        case "pending": .pending
        case "active": .active
        case "completed": .completed
        case "skipped": .skipped
        default: throw RuntimeStatusDecodeError(kind: "PhaseStatus", rawValue: raw)
        }
    }

    var wireValue: String {
        switch self {
        case .pending: "pending"
        case .active: "active"
        case .completed: "completed"
        case .skipped: "skipped"
        }
    }
}

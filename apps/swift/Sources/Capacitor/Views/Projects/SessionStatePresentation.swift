import Foundation

/// Canonical, single-source display attributes for a ``SessionState``.
///
/// The three fields are deliberately distinct and must not be substituted for one another:
/// - ``statusText`` — the short status word shown on chips/indicators (Working/Ready/Idle/...).
/// - ``accessibilityDescription`` — the longer descriptive VoiceOver string.
/// - ``telemetryLabel`` — the DEBUG/log shape; kept terse so existing DebugLog diffs stay quiet.
///
/// `SessionState` is the UniFFI-generated enum; these strings are a Swift-side presentation
/// concern and never cross the wire. This is the only place SessionState display strings are
/// declared — view layers read `state.presentation.*` rather than re-declaring switches.
struct SessionStatePresentation {
    let statusText: String
    let accessibilityDescription: String
    let telemetryLabel: String
}

extension SessionState {
    /// The single canonical presentation mapping for each session-state variant.
    var presentation: SessionStatePresentation {
        switch self {
        case .ready:
            SessionStatePresentation(
                statusText: "Ready",
                accessibilityDescription: "Ready for input",
                telemetryLabel: "Ready",
            )
        case .working:
            SessionStatePresentation(
                statusText: "Working",
                // Unified canonical value (the more descriptive of the two prior spellings).
                accessibilityDescription: "Currently working on a task",
                telemetryLabel: "Working",
            )
        case .waiting:
            SessionStatePresentation(
                statusText: "Waiting",
                accessibilityDescription: "Waiting for user action",
                telemetryLabel: "Waiting",
            )
        case .compacting:
            SessionStatePresentation(
                statusText: "Compacting",
                // Unified canonical value (the more descriptive of the two prior spellings).
                accessibilityDescription: "Compacting conversation history",
                telemetryLabel: "Compacting",
            )
        case .idle:
            SessionStatePresentation(
                statusText: "Idle",
                accessibilityDescription: "Session is idle",
                telemetryLabel: "Idle",
            )
        }
    }
}

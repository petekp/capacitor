import Foundation

// DateFormatting.swift
//
// Cached ISO8601 date formatters to avoid repeated allocations during view renders.
// ISO8601DateFormatter is expensive to create (~0.1ms per allocation). With 20 project
// cards rendering at 120fps, uncached formatters would allocate 2400 formatters/second.
//
// See: ProjectsView.isStale(), SessionStaleness.isReadyStale()

extension ISO8601DateFormatter {
    /// Shared formatter with fractional seconds support.
    /// Thread-safe for read operations (parsing dates).
    static let shared: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Shared formatter without fractional seconds (fallback).
    static let sharedWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

/// Parse ISO8601 timestamp with automatic fallback for fractional seconds.
/// Uses cached formatters to avoid allocation overhead in hot paths.
func parseISO8601Date(_ string: String) -> Date? {
    if let date = ISO8601DateFormatter.shared.date(from: string) {
        return date
    }
    return ISO8601DateFormatter.sharedWithoutFractionalSeconds.date(from: string)
}

import Foundation

// DateFormatting.swift
//
// Cached ISO8601 date formatters to avoid repeated allocations during view renders.
// ISO8601DateFormatter is expensive to create (~0.1ms per allocation). With 20 project
// cards rendering at 120fps, uncached formatters would allocate 2400 formatters/second.
//
// See: SessionStaleness.isSessionEffectivelyDead(), SessionStaleness.isRunFreshnessExpired()

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

private let microsecondISO8601Formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
    return formatter
}()

private func normalizeToMicrosecondISO8601(_ raw: String) -> String? {
    guard let dotIndex = raw.firstIndex(of: ".") else { return nil }
    var index = raw.index(after: dotIndex)
    var fraction = ""
    while index < raw.endIndex {
        let character = raw[index]
        if character >= "0", character <= "9" {
            fraction.append(character)
            index = raw.index(after: index)
        } else {
            break
        }
    }

    guard !fraction.isEmpty else { return nil }
    let timezoneSuffix = String(raw[index...])
    let prefix = String(raw[..<dotIndex])
    let normalizedFraction = fraction.count >= 6
        ? String(fraction.prefix(6))
        : fraction.padding(toLength: 6, withPad: "0", startingAt: 0)
    return "\(prefix).\(normalizedFraction)\(timezoneSuffix)"
}

/// Parse ISO8601 timestamp with automatic fallback for fractional seconds.
/// Uses cached formatters to avoid allocation overhead in hot paths.
func parseISO8601Date(_ string: String) -> Date? {
    if let date = ISO8601DateFormatter.shared.date(from: string) {
        return date
    }
    if let date = ISO8601DateFormatter.sharedWithoutFractionalSeconds.date(from: string) {
        return date
    }
    if let normalized = normalizeToMicrosecondISO8601(string) {
        return microsecondISO8601Formatter.date(from: normalized)
    }
    return nil
}

extension JSONDecoder.DateDecodingStrategy {
    static let capacitorISO8601 = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let date = parseISO8601Date(value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected ISO8601 date string.",
            )
        }
        return date
    }
}

/// Format the current wall-clock time using the canonical shared ISO8601 formatter.
func currentISO8601Timestamp() -> String {
    formatISO8601Timestamp(Date())
}

/// Format a supplied date using the canonical shared ISO8601 formatter.
func formatISO8601Timestamp(_ date: Date) -> String {
    ISO8601DateFormatter.shared.string(from: date)
}

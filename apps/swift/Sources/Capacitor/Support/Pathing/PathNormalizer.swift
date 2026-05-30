import Foundation

/// Path normalization for matching-time join keys.
///
/// C2-Phase2 SWIFTJOIN (STEP 3): the FINAL pure-string normalization step
/// (trailing-slash trimming + macOS lowercasing) is DELEGATED to the Rust core
/// via `normalizePathForMatching`, so Swift and Rust share ONE implementation of
/// the matching-time string normalizer and cannot drift on it.
///
/// What stays Swift-side (FS-touching / capture-time canonicalization that the
/// Rust pure-string matcher intentionally does NOT do):
///   * `URL.standardizedFileURL` — lexically collapses `.`/`..`. The Rust matcher
///     leaves these literal (replay determinism), which is the documented
///     `dotdot_segment` / `dot_segment` divergence. Keeping it Swift-side
///     preserves that intentional divergence.
///   * `resolvingSymlinksInPath` (when the path exists on disk) — load-bearing
///     symlink resolution that the `testSymlinkSeamMirrorsRust` conformance test
///     and the broader app rely on. The Rust pure-string matcher never resolves
///     symlinks; Rust resolves them only inside `workspace_id`'s `canonicalize`.
///
/// So Swift performs its FS-dependent transforms first, then hands the result to
/// the shared Rust pure-string normalizer for the trailing-slash/lowercase tail.
enum PathNormalizer {
    static func normalize(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        // FS-touching / capture-time canonicalization stays Swift-side (see type doc):
        // collapse `.`/`..` lexically, then resolve symlinks when the path exists.
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        let resolved: String = if FileManager.default.fileExists(atPath: standardized) {
            URL(fileURLWithPath: standardized).resolvingSymlinksInPath().path
        } else {
            standardized
        }

        // Delegate the pure-string matching normalization (trailing-slash trim +
        // macOS lowercasing) to the SAME Rust implementation the reducers use.
        return normalizePathForMatching(path: resolved)
    }
}

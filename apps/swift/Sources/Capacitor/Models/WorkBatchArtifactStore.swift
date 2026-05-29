import Foundation

/// Shared codec + filename rules for the five WorkBatch directory stores.
///
/// These stores form the agent<->app IPC file-drop contract: the in-session Claude
/// agent reads/writes the same artifacts. The encoder formatting, the date strategies,
/// and the filename sanitizer OUTPUT are all byte-level parts of that contract. This
/// type centralizes them so the only intentional divergence (the requests-only 80-char
/// cap) is a single parameter rather than three near-identical copies.
enum WorkBatchArtifactCodec {
    /// Canonical encoder for every WorkBatch artifact: `.iso8601` dates (no fractional
    /// seconds) plus `[.prettyPrinted, .sortedKeys]` formatting. Both are pinned by the
    /// golden tests and read by the agent side.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    /// Canonical decoder for every WorkBatch artifact: the lenient `.capacitorISO8601`
    /// strategy, which accepts both the store's own no-fractional-seconds form and the
    /// agent-written fractional-second form.
    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .capacitorISO8601
        return decoder
    }

    /// The single filename sanitizer for all five stores.
    ///
    /// Body is byte-identical to the historical per-store implementations (same
    /// lowercase + char map + run collapse + fallback). The only behavioral knobs are
    /// parameters:
    ///   - `fallback`: "task" for requests/claims/completions, "checkpoint" for
    ///     checkpoint requests/responses.
    ///   - `maxLength`: 80 for task requests (the documented requests-only cap), `nil`
    ///     (uncapped) for everyone else.
    static func sanitizedIdentifier(
        _ rawValue: String,
        fallback: String,
        maxLength: Int?,
    ) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(sanitized)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        let value = collapsed.isEmpty ? fallback : collapsed
        guard let maxLength else { return value }
        return String(value.prefix(maxLength))
    }
}

/// Generic on-disk store for a directory of single-record JSON files.
///
/// Every WorkBatch store is some subset of: resolve a directory under the worktree,
/// install the `.capacitor/` git-exclude marker + create the directory, write one
/// `Record` to a sanitized `<id>.json` path, and (optionally) load every `*.json`
/// back through the lenient decoder with a record-level predicate.
///
/// Operations are OPT-IN. The four readable stores supply a `load` predicate; the
/// write-only checkpoint-response store omits it and never exposes a load path.
/// Delete-with-dedup-rescan is intentionally NOT folded in here — it stays a
/// completion-report-specific capability.
struct JSONDirectoryStore<Record: Codable> {
    let worktreeURL: URL
    let fileManager: FileManager
    let relativeDirectory: String
    /// Maps a record-write `id` to its on-disk filename (carries the per-store
    /// fallback + cap rules, including the cross-store borrows).
    let fileName: (String) -> String
    /// Record-level keep/drop filter applied during `load()`. `nil` means this store
    /// is write-only and `load()` must not be called.
    let loadPredicate: ((Record) -> Bool)?

    init(
        worktreePath: String,
        fileManager: FileManager,
        relativeDirectory: String,
        fileName: @escaping (String) -> String,
        loadPredicate: ((Record) -> Bool)? = nil,
    ) {
        worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        self.fileManager = fileManager
        self.relativeDirectory = relativeDirectory
        self.fileName = fileName
        self.loadPredicate = loadPredicate
    }

    var directoryURL: URL {
        worktreeURL.appendingPathComponent(relativeDirectory, isDirectory: true)
    }

    func url(forID id: String) -> URL {
        directoryURL.appendingPathComponent(fileName(id))
    }

    /// Load every decodable `*.json` whose record passes `loadPredicate`, pairing each
    /// surviving record with its source URL. Returns `[]` when the directory is absent.
    func load() throws -> [(record: Record, url: URL)] {
        guard let loadPredicate else { return [] }
        guard fileManager.fileExists(atPath: directoryURL.path) else { return [] }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
        )
        let decoder = WorkBatchArtifactCodec.makeDecoder()

        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let record = try? decoder.decode(Record.self, from: data),
                      loadPredicate(record)
                else {
                    return nil
                }
                return (record, url)
            }
    }

    /// Install the git-exclude marker, ensure the directory exists, then atomically
    /// write `record` to the sanitized path for `id`.
    @discardableResult
    func write(_ record: Record, id: String) throws -> URL {
        try? WorkBatchMetadataIgnoreInstaller.install(
            in: worktreeURL.path,
            fileManager: fileManager,
        )
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
        )

        let url = url(forID: id)
        try WorkBatchArtifactCodec.makeEncoder().encode(record).write(to: url, options: .atomic)
        return url
    }
}

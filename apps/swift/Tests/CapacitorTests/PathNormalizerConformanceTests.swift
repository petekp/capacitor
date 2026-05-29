@testable import Capacitor
import Foundation
import XCTest

/// C2-Phase1 Swift conformance stage.
///
/// Reads the SHARED cross-language fixture corpus the Rust stage checked in
/// (`core/capacitor-core/tests/fixtures/path_identity_corpus.json`, the source
/// of truth) and pins Swift's path-identity outputs against it so cross-language
/// drift is LOUD.
///
/// The join this guards lives at `SessionStateManager.swift:737`
/// (Swift-recomputed `project.workspaceId` == Rust-provided `state.workspaceId`),
/// today rescued by path-containment fallbacks. This test makes the underlying
/// key-derivation drift between the two languages explicit rather than hidden
/// behind those fallbacks.
///
/// Per corpus row:
///   * `must_agree`  -> Swift `normalize` / `fromPath` are asserted EQUAL to the
///                      Rust-recorded `expected_*` values (the drift guard).
///   * `documented_divergence` -> Swift is EXPECTED to differ; we pin the CURRENT
///                      Swift value (Swift-side drift guard) AND assert the
///                      divergence still holds vs the Rust source-of-truth value.
///                      If a row converges, the test fails and tells you to
///                      reclassify it.
///
/// `documented_divergence` covers TWO kinds, matching the corpus:
///   1. Intentional/by-design divergence (the `dotdot_segment` / `dot_segment`
///      rows): Rust `normalize_path_for_matching` is a PURE STRING op that leaves
///      `.`/`..` literal for replay determinism, while Swift's
///      `URL.standardizedFileURL` lexically collapses them.
///   2. CURRENT cross-language `workspace_id` drift flagged `phase2_reconcile`
///      in the corpus (the `trailing_slash` / `double_trailing_slash` /
///      `git_project_id` rows). These USED to be mislabeled `must_agree` with a
///      false "both languages compute it identically" note; the C2-Phase1 test
///      DISCOVERED they actually diverge on `workspace_id`. They are now honestly
///      classified as `documented_divergence` + `phase2_reconcile: true`. The
///      actual fix is the DEFERRED C2-Phase2 key/normalizer reconciliation; today
///      they are rescued only by SessionStateManager runtime path-containment
///      fallbacks. We pin the CURRENT Swift value and cross-reference the corpus.
final class PathNormalizerConformanceTests: XCTestCase {
    // MARK: - Corpus model

    private struct CorpusRow: Decodable {
        let id: String
        let input: String
        let agreement: String
        let expectedNormalize: String
        let expectedDefaultWorkspaceId: String
        let divergenceReason: String?
        let phase2Reconcile: Bool?
        let note: String?

        enum CodingKeys: String, CodingKey {
            case id
            case input
            case agreement
            case expectedNormalize = "expected_normalize"
            case expectedDefaultWorkspaceId = "expected_default_workspace_id"
            case divergenceReason = "divergence_reason"
            case phase2Reconcile = "phase2_reconcile"
            case note
        }
    }

    private struct Corpus: Decodable {
        let staticRows: [CorpusRow]

        enum CodingKeys: String, CodingKey {
            case staticRows = "static_rows"
        }
    }

    // MARK: - Pinned CURRENT Swift outputs for documented_divergence rows

    /// CURRENT Swift `PathNormalizer.normalize` outputs for every
    /// `documented_divergence` row. Pinning these makes Swift-side drift LOUD; the
    /// values are asserted to STILL differ from the Rust `expected_normalize`
    /// (where applicable) so a silent convergence forces a reclassification.
    ///
    ///   * dotdot_segment / dot_segment: `URL.standardizedFileURL` lexically
    ///     collapses `..` / `.`, so both reduce to `plain_abs` (Rust keeps them
    ///     literal). normalize DIVERGES.
    ///   * trailing_slash / double_trailing_slash: Swift strips trailing slashes in
    ///     `PathNormalizer.normalize`, so normalize AGREES with Rust here — the
    ///     divergence on these rows is on `workspace_id`, not `normalize`.
    ///   * git_project_id: `.git` is a normal segment for the string normalizer, so
    ///     normalize AGREES with Rust — again the divergence is on `workspace_id`.
    private let pinnedSwiftNormalize: [String: String] = [
        "dotdot_segment": "/users/pete/code/myrepo",
        "dot_segment": "/users/pete/code/myrepo",
        "trailing_slash": "/users/pete/code/myrepo",
        "double_trailing_slash": "/users/pete/code/myrepo",
        "git_project_id": "/users/pete/code/myrepo/.git",
    ]

    /// CURRENT Swift `WorkspaceIdentity.fromPath` outputs for every
    /// `documented_divergence` row. Each value is the C2-Phase2 reconcile target /
    /// design-divergence reality, NOT the Rust source-of-truth value.
    private let pinnedSwiftWorkspaceId: [String: String] = [
        // ".."/"." collapse to plain_abs, so Swift workspace_id == plain_abs's.
        "dotdot_segment": "5d699b305e97dd1568da5aaf1ec9a3ab",
        "dot_segment": "5d699b305e97dd1568da5aaf1ec9a3ab",
        // trailing/double-trailing: Swift strips the slash BEFORE hashing, so its
        // workspace_id collides with plain_abs while Rust hashes the raw slashed
        // input. C2-Phase2 reconcile target (phase2_reconcile: true).
        "trailing_slash": "5d699b305e97dd1568da5aaf1ec9a3ab",
        "double_trailing_slash": "5d699b305e97dd1568da5aaf1ec9a3ab",
        // git_project_id: Swift has NO `.git` awareness; it hashes
        // "/users/pete/code/myrepo/.git|/users/pete/code/myrepo/.git" whereas Rust
        // rewrites the relative half to ".git". C2-Phase2 reconcile target.
        "git_project_id": "f11988aa7d1c2ad9f893c462fef23134",
    ]

    /// Rows whose divergence is INTENTIONAL/by-design (normalize differs by
    /// construction). For these we additionally assert normalize diverges from Rust.
    /// (The `phase2_reconcile` rows agree on normalize and only diverge on
    /// workspace_id, so we don't assert a normalize divergence for them.)
    private let intentionalNormalizeDivergenceRows: Set<String> = [
        "dotdot_segment",
        "dot_segment",
    ]

    // MARK: - Corpus loading

    /// Resolves the shared corpus by walking up from this test file's location to
    /// the repo root (the test target ships no bundled resources, mirroring how the
    /// Rust stage reads it relative to `CARGO_MANIFEST_DIR`). 4 parent hops:
    /// CapacitorTests -> Tests -> swift -> apps -> <repo root>.
    private func loadCorpus(file: StaticString = #filePath) throws -> Corpus {
        var dir = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        for _ in 0 ..< 4 {
            dir.deleteLastPathComponent()
        }
        let corpusURL = dir
            .appendingPathComponent("core")
            .appendingPathComponent("capacitor-core")
            .appendingPathComponent("tests")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("path_identity_corpus.json")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: corpusURL.path),
            "shared corpus not found at \(corpusURL.path) — did the Rust stage move it?",
        )

        let data = try Data(contentsOf: corpusURL)
        return try JSONDecoder().decode(Corpus.self, from: data)
    }

    // MARK: - Tests

    func testCorpusLoadsStaticRows() throws {
        let corpus = try loadCorpus()
        XCTAssertFalse(corpus.staticRows.isEmpty, "corpus must contain static rows")
    }

    /// Cross-language drift guard for `must_agree` rows.
    ///
    /// After the C2-Phase1 reclassification, EVERY remaining `must_agree` row
    /// genuinely agrees with Rust on BOTH `normalize` and `workspace_id`. There is
    /// no longer a "known must_agree drift" exception path: the three rows that
    /// actually diverged on `workspace_id` (trailing_slash, double_trailing_slash,
    /// git_project_id) are now honestly classified `documented_divergence` and
    /// handled by `testDocumentedDivergenceRowsPinCurrentSwiftBehavior`.
    func testMustAgreeRowsMatchRust() throws {
        let corpus = try loadCorpus()
        var sawMustAgree = false

        for row in corpus.staticRows where row.agreement == "must_agree" {
            sawMustAgree = true

            let swiftNormalize = PathNormalizer.normalize(row.input)
            let swiftWorkspaceId = WorkspaceIdentity.fromPath(row.input)

            XCTAssertEqual(
                swiftNormalize,
                row.expectedNormalize,
                "NORMALIZE DRIFT (must_agree) row \(row.id) input \(row.input): " +
                    "Swift produced \(swiftNormalize), Rust expected \(row.expectedNormalize)",
            )
            XCTAssertEqual(
                swiftWorkspaceId,
                row.expectedDefaultWorkspaceId,
                "WORKSPACE_ID DRIFT (must_agree) row \(row.id) input \(row.input): " +
                    "Swift produced \(swiftWorkspaceId), Rust expected \(row.expectedDefaultWorkspaceId). " +
                    "If this is a real, currently-unavoidable cross-language drift, RECLASSIFY the " +
                    "corpus row to documented_divergence (+ phase2_reconcile) rather than asserting equality.",
            )
        }

        XCTAssertTrue(sawMustAgree, "corpus must contain at least one must_agree row")
    }

    /// `documented_divergence` rows: Swift is EXPECTED to differ from Rust. We pin
    /// the CURRENT Swift value (so future Swift-side drift is loud) and assert the
    /// divergence STILL holds against the Rust source-of-truth value.
    ///
    /// This now covers BOTH kinds of divergence (see the type doc):
    ///   * intentional `.`/`..` rows (normalize AND workspace_id diverge), and
    ///   * `phase2_reconcile` rows where only `workspace_id` diverges (normalize
    ///     agrees because Swift strips trailing slashes / treats `.git` as a plain
    ///     segment). For those we assert the workspace_id divergence is the
    ///     C2-Phase2 reconcile target.
    func testDocumentedDivergenceRowsPinCurrentSwiftBehavior() throws {
        let corpus = try loadCorpus()

        var sawDivergence = false
        var sawPhase2Reconcile = false
        for row in corpus.staticRows where row.agreement == "documented_divergence" {
            sawDivergence = true

            let swiftNormalize = PathNormalizer.normalize(row.input)
            let swiftWorkspaceId = WorkspaceIdentity.fromPath(row.input)

            guard
                let pinnedNormalize = pinnedSwiftNormalize[row.id],
                let pinnedWorkspaceId = pinnedSwiftWorkspaceId[row.id]
            else {
                XCTFail(
                    "documented_divergence row \(row.id) is not pinned in this test — " +
                        "add its CURRENT Swift normalize + workspace_id value and cite the reason: " +
                        (row.divergenceReason ?? "(no reason recorded)"),
                )
                continue
            }

            // Pin CURRENT Swift behavior (drift guard for the Swift side).
            XCTAssertEqual(
                swiftNormalize,
                pinnedNormalize,
                "Swift normalize for documented_divergence row \(row.id) moved off its " +
                    "pinned value \(pinnedNormalize) (now \(swiftNormalize))",
            )
            XCTAssertEqual(
                swiftWorkspaceId,
                pinnedWorkspaceId,
                "Swift workspace_id for documented_divergence row \(row.id) moved off its " +
                    "pinned value \(pinnedWorkspaceId) (now \(swiftWorkspaceId))",
            )

            // The workspace_id divergence vs the Rust source of truth must STILL
            // hold for every documented_divergence row. If it ever converges, the
            // languages reconciled and the row should be reclassified to must_agree.
            XCTAssertNotEqual(
                swiftWorkspaceId,
                row.expectedDefaultWorkspaceId,
                "documented_divergence row \(row.id) workspace_id CONVERGED with Rust " +
                    "(\(row.expectedDefaultWorkspaceId)) — reclassify the corpus row to must_agree",
            )

            // For the by-design `.`/`..` rows, normalize ALSO diverges by
            // construction; assert that too. The phase2_reconcile rows agree on
            // normalize (only workspace_id drifts), so we don't assert it for them.
            if intentionalNormalizeDivergenceRows.contains(row.id) {
                XCTAssertNotEqual(
                    swiftNormalize,
                    row.expectedNormalize,
                    "by-design documented_divergence row \(row.id) normalize CONVERGED with Rust " +
                        "(\(row.expectedNormalize)) — reclassify the corpus row to must_agree",
                )
            }

            // The reclassified rows carry phase2_reconcile: true. Surface a loud,
            // grep-able marker so the C2-Phase2 reconcile target is visible in logs.
            if row.phase2Reconcile == true {
                sawPhase2Reconcile = true
                print(
                    "C2-PHASE2 RECONCILE TARGET: documented_divergence row \(row.id) DISAGREES on " +
                        "workspace_id (Rust expected \(row.expectedDefaultWorkspaceId), Swift produced " +
                        "\(swiftWorkspaceId)) — current cross-language drift, rescued today only by " +
                        "runtime path-containment fallbacks.",
                )
            }
        }

        XCTAssertTrue(sawDivergence, "corpus must contain at least one documented_divergence row")
        XCTAssertTrue(
            sawPhase2Reconcile,
            "corpus must contain at least one phase2_reconcile documented_divergence row " +
                "(the C2-Phase1 discovery of trailing_slash / double_trailing_slash / git_project_id drift)",
        )
    }

    // MARK: - FS-dependent seams (mirror the Rust live-tmpdir tests)

    /// Symlink seam (`fs_dependent_cases.symlinked_dir`, documented_divergence).
    ///
    /// Mirrors the Rust test
    /// `corpus_fs_dependent_symlink_normalize_keeps_link_workspace_id_resolves`:
    /// build a real tmpdir symlink (linkdir -> realdir) and pin the CURRENT Swift
    /// behavior, then cross-reference the Rust finding so the Rust-vs-Swift symlink
    /// seam is documented explicitly.
    ///
    /// Rust's finding (from that test):
    ///   * Rust `normalize_path_for_matching` is a PURE STRING op and KEEPS the link
    ///     path (link != target).
    ///   * Rust `workspace_id` calls `std::fs::canonicalize`, which RESOLVES the
    ///     symlink, so link == target.
    ///
    /// Swift's behavior (pinned here): `PathNormalizer.normalize` calls
    /// `resolvingSymlinksInPath` WHEN THE FILE EXISTS, so on a real on-disk link
    /// Swift RESOLVES the symlink in `normalize` (link normalize == target normalize)
    /// — the OPPOSITE of Rust's pure-string normalize. `WorkspaceIdentity.fromPath`
    /// hashes that already-resolved normalize, so Swift's workspace_id(link) ==
    /// workspace_id(target) too. The seam: both languages collapse link/target for
    /// `workspace_id`, but they do it at DIFFERENT layers — Rust at the
    /// `canonicalize` step inside `workspace_id` (normalize still keeps the link),
    /// Swift inside `normalize` itself (because the path exists on disk).
    func testSymlinkSeamMirrorsRust() throws {
        let fm = FileManager.default
        let tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("capacitor-path-identity-symlink-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        // Mirror the Rust tmpdir construction: realdir target + linkdir symlink.
        let target = tempRoot.appendingPathComponent("realdir", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        let link = tempRoot.appendingPathComponent("linkdir", isDirectory: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: target)

        let linkPath = link.path
        let targetPath = target.path

        let linkNormalize = PathNormalizer.normalize(linkPath)
        let targetNormalize = PathNormalizer.normalize(targetPath)
        let linkWorkspaceId = WorkspaceIdentity.fromPath(linkPath)
        let targetWorkspaceId = WorkspaceIdentity.fromPath(targetPath)

        // Sanity: the link normalize must NOT still be the verbatim link path
        // string — Swift resolves it because the file exists on disk. (Lowercased
        // on macOS, so compare case-insensitively against the expected suffix.)
        XCTAssertFalse(
            linkNormalize.hasSuffix("/linkdir"),
            "Expected Swift normalize to RESOLVE the on-disk symlink (Rust keeps the link " +
                "string; Swift resolves it via resolvingSymlinksInPath), but got \(linkNormalize)",
        )

        // CURRENT Swift behavior, pinned + documented:
        //   * normalize RESOLVES the link, so link normalize == target normalize.
        //     This is the documented seam vs Rust, where normalize keeps the link.
        XCTAssertEqual(
            linkNormalize,
            targetNormalize,
            "Swift normalize should resolve the symlink so link and target normalize equally " +
                "(this is the Rust-vs-Swift seam: Rust normalize KEEPS the link string, see Rust " +
                "test corpus_fs_dependent_symlink_normalize_keeps_link_workspace_id_resolves)",
        )
        //   * workspace_id collapses link == target (like Rust, but via normalize
        //     rather than via canonicalize inside workspace_id).
        XCTAssertEqual(
            linkWorkspaceId,
            targetWorkspaceId,
            "Swift workspace_id should collapse link and target (matches Rust's canonicalize-based " +
                "collapse, though Swift collapses earlier inside normalize)",
        )
    }

    /// Git-worktree stability (`fs_dependent_cases.git_worktree_stability`,
    /// must_agree) — ACKNOWLEDGED GAP, not silently skipped.
    ///
    /// Worktree stability requires constructing a real linked git worktree: a
    /// primary repo with a `.git/` directory plus a sibling worktree whose `.git`
    /// is a FILE containing `gitdir:` pointing at `<repo>/.git/worktrees/<name>`
    /// with a `commondir` of `../..`. Building that deterministically in the Swift
    /// unit-test environment is impractical (it depends on git's on-disk worktree
    /// layout and FS canonicalization), so this seam is OWNED by the Rust test
    /// `workspace_id_is_stable_across_worktrees`, which already pins that a file in
    /// the primary worktree and a file in the linked worktree resolve to equal
    /// project_id / project_path / workspace_id.
    ///
    /// This placeholder records the gap explicitly so it is acknowledged rather
    /// than invisible. If a future change lets us build a worktree in the Swift
    /// test sandbox, mirror the Rust construction here and assert
    /// `WorkspaceIdentity` stability across the two worktrees.
    func testWorktreeStabilityOwnedByRust() throws {
        // No Swift assertion: worktree stability is owned by the Rust test
        // `workspace_id_is_stable_across_worktrees`. See the doc comment above and
        // the `git_worktree_stability` row in path_identity_corpus.json.
        throw XCTSkip(
            "Worktree stability is owned by the Rust test workspace_id_is_stable_across_worktrees; " +
                "a real linked git worktree cannot be constructed deterministically in the Swift " +
                "unit-test environment. Acknowledged gap (see git_worktree_stability corpus row), " +
                "not a silent omission.",
        )
    }
}

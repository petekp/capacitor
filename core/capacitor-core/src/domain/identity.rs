use std::path::{Path, PathBuf};

const MAX_BOUNDARY_DEPTH: usize = 20;
const PROJECT_MARKERS: &[(&str, u8)] = &[
    ("CLAUDE.md", 1),
    ("package.json", 2),
    ("Cargo.toml", 2),
    ("pyproject.toml", 2),
    ("go.mod", 2),
    ("pubspec.yaml", 2),
    ("Project.toml", 2),
    ("deno.json", 2),
    (".git", 3),
    ("Makefile", 4),
    ("CMakeLists.txt", 4),
];
const PACKAGE_MARKERS: &[&str] = &[
    "package.json",
    "Cargo.toml",
    "pyproject.toml",
    "go.mod",
    "pubspec.yaml",
    "Project.toml",
    "deno.json",
];
const IGNORED_DIRECTORIES: &[&str] = &[
    "node_modules",
    "vendor",
    ".git",
    "__pycache__",
    "target",
    "dist",
    "build",
    ".next",
    ".output",
    "venv",
    ".venv",
    "env",
    ".turbo",
    ".cache",
];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectIdentity {
    pub project_path: String,
    pub project_id: String,
}

#[derive(Debug, Clone)]
struct GitInfo {
    worktree_root: PathBuf,
    repo_root: PathBuf,
    common_dir: PathBuf,
    is_worktree: bool,
}

#[derive(Debug, Clone)]
struct ProjectBoundary {
    path: PathBuf,
    marker: &'static str,
    priority: u8,
}

#[must_use]
pub(crate) fn display_name(project_path: &str) -> String {
    project_path
        .split('/')
        .rfind(|part| !part.is_empty())
        .unwrap_or(project_path)
        .to_string()
}

#[must_use]
pub(crate) fn normalize_path_for_matching(path: &str) -> String {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let without_trailing = if trimmed == "/" {
        "/"
    } else {
        trimmed.trim_end_matches('/')
    };

    let normalized = if without_trailing.is_empty() {
        "/"
    } else {
        without_trailing
    };

    #[cfg(target_os = "macos")]
    {
        normalized.to_lowercase()
    }

    #[cfg(not(target_os = "macos"))]
    {
        normalized.to_string()
    }
}

#[must_use]
pub(crate) fn default_workspace_id(project_path: &str) -> String {
    // C2-Phase2 RECONCILE (STEP 1): make the project-list key GIT-AWARE so it
    // converges to the session/routing key. The session/routing reducers derive
    // their workspace_id by first resolving project identity (git common_dir +
    // repo_root) and then hashing via `workspace_id`. Deriving the project-list
    // key by hashing the raw path twice (`workspace_id(path, path)`) forked a git
    // project into two keys (`repo|repo` vs `repo/.git|`), so a pinned project
    // could miss its live session state unless a runtime path-containment
    // fallback rescued it. Resolving identity here first makes the project-list
    // key equal the session key for the same project.
    //
    // When the path does not resolve to a project boundary (e.g. it does not
    // exist on disk, as in the deterministic corpus rows), we fall back to the
    // raw path as both project_id and project_path — identical to the historical
    // behavior — so non-git inputs keep their stable, FS-independent key.
    match resolve_project_identity(project_path) {
        Some(identity) => workspace_id(&identity.project_id, &identity.project_path),
        None => workspace_id(project_path, project_path),
    }
}

#[must_use]
pub(crate) fn workspace_id(project_id: &str, project_path: &str) -> String {
    // C2-Phase2 RECONCILE (STEP 1b): normalize the inputs (trim trailing slashes,
    // lowercase on macOS) BEFORE canonicalize/hash so a trailing slash or
    // double-trailing-slash cannot fork the workspace_id. This converges the
    // trailing_slash / double_trailing_slash corpus rows onto the plain_abs key
    // and matches the Swift side, which normalizes first.
    let project_id = normalize_path_for_matching(project_id);
    let project_path = normalize_path_for_matching(project_path);
    let project_id = canonicalize_path(Path::new(&project_id));
    let project_path = canonicalize_path(Path::new(&project_path));
    let relative = workspace_relative_path(&project_id, &project_path);
    let source = format!("{}|{}", project_id.to_string_lossy(), relative);

    #[cfg(target_os = "macos")]
    let source = source.to_lowercase();

    format!("{:x}", md5::compute(source))
}

pub(crate) fn resolve_project_identity(path: &str) -> Option<ProjectIdentity> {
    let boundary = find_project_boundary(path)?;
    let git_info = resolve_git_info(&boundary.path);

    let canonical_boundary = git_info
        .as_ref()
        .map(|info| canonicalize_worktree_path(&boundary.path, info))
        .unwrap_or_else(|| canonicalize_path(&boundary.path));

    let project_id_path = git_info
        .as_ref()
        .map(|info| info.common_dir.clone())
        .unwrap_or_else(|| canonical_boundary.clone());

    Some(ProjectIdentity {
        project_path: normalize_path_for_matching(&path_to_string(&canonical_boundary)),
        project_id: normalize_path_for_matching(&path_to_string(&project_id_path)),
    })
}

fn find_project_boundary(file_path: &str) -> Option<ProjectBoundary> {
    let path = Path::new(file_path);
    if !path.exists() {
        return None;
    }

    let start = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent()?.to_path_buf()
    };

    let mut current = Some(start);
    let mut depth = 0;
    let mut best_boundary: Option<ProjectBoundary> = None;

    while let Some(dir) = current {
        if depth >= MAX_BOUNDARY_DEPTH {
            break;
        }

        if let Some(dir_name) = dir.file_name().and_then(|name| name.to_str()) {
            if IGNORED_DIRECTORIES.contains(&dir_name) {
                best_boundary = None;
                current = dir.parent().map(Path::to_path_buf);
                depth += 1;
                continue;
            }
        }

        for (marker, priority) in PROJECT_MARKERS {
            if has_marker(&dir, marker) {
                let candidate = ProjectBoundary {
                    path: dir.clone(),
                    marker,
                    priority: *priority,
                };

                if *priority == 1 {
                    if let Some(existing) = &best_boundary {
                        if PACKAGE_MARKERS.contains(&existing.marker) {
                            continue;
                        }
                    }
                    return Some(candidate);
                }

                match &best_boundary {
                    None => best_boundary = Some(candidate),
                    Some(existing) if candidate.priority < existing.priority => {
                        best_boundary = Some(candidate);
                    }
                    _ => {}
                }

                break;
            }
        }

        current = dir.parent().map(Path::to_path_buf);
        depth += 1;
    }

    best_boundary
}

fn has_marker(dir: &Path, marker: &str) -> bool {
    dir.join(marker).exists()
}

fn workspace_relative_path(project_id: &Path, project_path: &Path) -> String {
    let repo_root = repo_root_from_project_id(project_id);
    if let Some(repo_root) = repo_root {
        if let Ok(relative) = project_path.strip_prefix(&repo_root) {
            return relative.to_string_lossy().to_string();
        }
    }

    project_path.to_string_lossy().to_string()
}

fn repo_root_from_project_id(project_id: &Path) -> Option<PathBuf> {
    if project_id.file_name().and_then(|name| name.to_str()) == Some(".git") {
        return project_id.parent().map(Path::to_path_buf);
    }

    None
}

fn resolve_git_info(path: &Path) -> Option<GitInfo> {
    let start = if path.is_dir() {
        path.to_path_buf()
    } else {
        path.parent()?.to_path_buf()
    };

    let mut current = Some(start);
    while let Some(dir) = current {
        let git_entry = dir.join(".git");
        if git_entry.exists() {
            if git_entry.is_dir() {
                let repo_root = canonicalize_path(&dir);
                let common_dir = canonicalize_path(&git_entry);
                return Some(GitInfo {
                    worktree_root: repo_root.clone(),
                    repo_root,
                    common_dir,
                    is_worktree: false,
                });
            }

            let git_dir = parse_gitdir(&git_entry, &dir)?;
            if let Some(common_dir) = parse_commondir(&git_dir) {
                let repo_root = common_dir.parent().unwrap_or(&dir).to_path_buf();
                return Some(GitInfo {
                    worktree_root: canonicalize_path(&dir),
                    repo_root: canonicalize_path(&repo_root),
                    common_dir: canonicalize_path(&common_dir),
                    is_worktree: true,
                });
            }

            return Some(GitInfo {
                worktree_root: canonicalize_path(&dir),
                repo_root: canonicalize_path(&dir),
                common_dir: canonicalize_path(&git_dir),
                is_worktree: false,
            });
        }

        let parent = dir.parent().map(Path::to_path_buf);
        if parent.as_ref() == Some(&dir) {
            break;
        }
        current = parent;
    }

    None
}

fn parse_gitdir(git_file: &Path, worktree_root: &Path) -> Option<PathBuf> {
    let contents = std::fs::read_to_string(git_file).ok()?;
    let line = contents
        .lines()
        .find(|line| line.to_ascii_lowercase().starts_with("gitdir:"))?;
    let raw = line.get("gitdir:".len()..)?.trim();
    if raw.is_empty() {
        return None;
    }

    Some(resolve_git_path(worktree_root, raw))
}

fn parse_commondir(git_dir: &Path) -> Option<PathBuf> {
    let commondir_path = git_dir.join("commondir");
    if !commondir_path.exists() {
        return None;
    }

    let contents = std::fs::read_to_string(commondir_path).ok()?;
    let raw = contents.trim();
    if raw.is_empty() {
        return None;
    }

    Some(resolve_git_path(git_dir, raw))
}

fn resolve_git_path(base: &Path, raw: &str) -> PathBuf {
    let path = Path::new(raw);
    if path.is_absolute() {
        canonicalize_path(path)
    } else {
        canonicalize_path(&base.join(path))
    }
}

fn canonicalize_worktree_path(path: &Path, git_info: &GitInfo) -> PathBuf {
    if !git_info.is_worktree {
        return canonicalize_path(path);
    }

    let normalized_path = canonicalize_path(path);
    let worktree_root = canonicalize_path(&git_info.worktree_root);
    if let Ok(relative) = normalized_path.strip_prefix(&worktree_root) {
        return git_info.repo_root.join(relative);
    }

    normalized_path
}

fn canonicalize_path(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    /// One static (non-FS) row of the shared cross-language path-identity corpus.
    ///
    /// See `core/capacitor-core/tests/fixtures/path_identity_corpus.json`. These
    /// rows use paths that do NOT exist on disk so `std::fs::canonicalize` (Rust)
    /// and `resolvingSymlinksInPath` (Swift) both fall through to their
    /// lexical/string behavior, keeping the corpus deterministic across machines.
    #[derive(Debug, Deserialize)]
    struct CorpusRow {
        id: String,
        input: String,
        agreement: String,
        expected_normalize: String,
        expected_default_workspace_id: String,
    }

    #[derive(Debug, Deserialize)]
    struct Corpus {
        static_rows: Vec<CorpusRow>,
    }

    fn load_corpus() -> Corpus {
        let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("path_identity_corpus.json");
        let raw = std::fs::read_to_string(&path)
            .unwrap_or_else(|err| panic!("read corpus {}: {err}", path.display()));
        serde_json::from_str(&raw).expect("parse path_identity_corpus.json")
    }

    #[test]
    fn normalize_path_trims_trailing_slashes() {
        assert_eq!(normalize_path_for_matching("/repo/"), "/repo");
        assert_eq!(normalize_path_for_matching("/repo//"), "/repo");
        assert_eq!(normalize_path_for_matching("/"), "/");
    }

    /// Pins the CURRENT Rust outputs for every static corpus row so future drift in
    /// `normalize_path_for_matching` / `default_workspace_id` is LOUD (the JSON is the
    /// shared source of truth the Swift conformance stage asserts against).
    ///
    /// `agreement` is recorded for cross-language consumers; Rust is the source of
    /// truth either way, so this test pins Rust outputs for ALL rows regardless of
    /// whether Swift is expected to match (`must_agree`) or differ
    /// (`documented_divergence`). Note that `documented_divergence` covers two kinds:
    /// intentional/by-design divergence (e.g. the `.`/`..` replay-determinism rows)
    /// and CURRENT cross-language workspace_id drift flagged `phase2_reconcile: true`
    /// in the corpus (the trailing_slash / double_trailing_slash / git_project_id
    /// rows that C2-Phase2 must reconcile). Rust pins its own value for both kinds.
    #[test]
    fn corpus_pins_normalize_and_workspace_id() {
        let corpus = load_corpus();
        assert!(
            !corpus.static_rows.is_empty(),
            "corpus must contain static rows"
        );

        for row in &corpus.static_rows {
            assert_eq!(
                normalize_path_for_matching(&row.input),
                row.expected_normalize,
                "normalize drift for corpus row {:?} (input {:?})",
                row.id,
                row.input
            );
            assert_eq!(
                default_workspace_id(&row.input),
                row.expected_default_workspace_id,
                "default_workspace_id drift for corpus row {:?} (input {:?})",
                row.id,
                row.input
            );
            assert!(
                row.agreement == "must_agree" || row.agreement == "documented_divergence",
                "corpus row {:?} has unknown agreement {:?}",
                row.id,
                row.agreement
            );
        }
    }

    #[test]
    fn workspace_id_is_stable_for_case_changes() {
        let first = workspace_id("/Users/Pete/Code/Repo/.git", "/Users/Pete/Code/Repo");
        let second = workspace_id("/users/pete/code/repo/.git", "/users/pete/code/repo");
        assert_eq!(first, second);
    }

    /// C2-Phase2 RECONCILED (was the DEFERRED hazard pin). For the SAME git project, the
    /// pinned-project-list key derived via `default_workspace_id(repo_path)` now AGREES with
    /// the git-aware `workspace_id(common_dir, repo_path)` because `default_workspace_id`
    /// resolves project identity (git common_dir + repo_root) before hashing.
    ///
    /// This mirrors the corpus `rust_internal_divergence` block, which now records
    /// `they_match: true` against the converged git-aware value. It uses a live tmpdir
    /// because the convergence only fires when `.git` exists on disk for
    /// `resolve_project_identity` to detect (the static literal paths the former pin used
    /// could not converge, since neither path existed for git resolution to fire).
    #[test]
    fn default_workspace_id_agrees_with_git_aware_for_same_project_c2_phase2() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("myrepo");
        let repo_git = repo_root.join(".git");
        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::write(repo_root.join("CLAUDE.md"), "# repo").expect("project marker");

        let repo_path = repo_root.to_string_lossy().to_string();
        let identity = resolve_project_identity(&repo_path).expect("repo identity");

        let default_key = default_workspace_id(&repo_path);
        let git_aware_key = workspace_id(&identity.project_id, &identity.project_path);

        // Reconciled behavior: the two keys for the SAME project now AGREE.
        assert_eq!(
            default_key, git_aware_key,
            "C2-Phase2 regression: default_workspace_id and git-aware workspace_id diverged \
             again for the same project. The project-list key must stay git-aware so a pinned \
             project joins session state without relying on path-containment fallbacks."
        );
    }

    /// Pins the symlink seam (`fs_dependent_cases.symlinked_dir`, documented_divergence).
    ///
    /// Within Rust itself, `normalize_path_for_matching` and `workspace_id` treat a symlink
    /// DIFFERENTLY:
    /// - `normalize_path_for_matching` is a pure string op and KEEPS the link path (it does
    ///   NOT resolve the symlink).
    /// - `workspace_id` calls `std::fs::canonicalize`, which RESOLVES the symlink, so the link
    ///   and its target produce the SAME workspace_id.
    ///
    /// Swift's `PathNormalizer.normalize` additionally calls `resolvingSymlinksInPath` when the
    /// file exists, so Swift's normalize will resolve the link where Rust's does not — hence
    /// `documented_divergence` for normalize on this row.
    #[test]
    fn corpus_fs_dependent_symlink_normalize_keeps_link_workspace_id_resolves() {
        let temp = tempfile::tempdir().expect("temp dir");
        let target = temp.path().join("realdir");
        std::fs::create_dir_all(&target).expect("create target dir");
        let link = temp.path().join("linkdir");
        std::os::unix::fs::symlink(&target, &link).expect("create symlink");

        let link_str = link.to_string_lossy().to_string();
        let target_str = target.to_string_lossy().to_string();

        // normalize KEEPS the link path (only trims/lowercases); it does NOT resolve to target.
        let normalized = normalize_path_for_matching(&link_str);
        assert!(
            normalized.ends_with("/linkdir"),
            "normalize unexpectedly resolved the symlink: {normalized:?}"
        );
        assert_ne!(
            normalize_path_for_matching(&link_str),
            normalize_path_for_matching(&target_str),
            "normalize should treat link and target as DISTINCT strings"
        );

        // workspace_id RESOLVES the symlink via canonicalize, so link == target.
        assert_eq!(
            workspace_id(&link_str, &link_str),
            workspace_id(&target_str, &target_str),
            "workspace_id should canonicalize the symlink so link and target collide"
        );
    }

    /// C2-Phase2 RECONCILE convergence proof (live tmpdir).
    ///
    /// For the SAME real git project, the project-list key derived via
    /// `default_workspace_id(repo_path)` MUST equal the git-aware
    /// `workspace_id(common_dir, repo_path)` that the session/routing reducers
    /// compute through `resolve_project_identity`. Before STEP 1 these DIVERGE
    /// (default_workspace_id hashed `repo|repo` while the git-aware key hashed
    /// `repo/.git|`), so a pinned project keyed one way MISSED session state
    /// keyed the other way unless a runtime path-containment fallback rescued it.
    ///
    /// This is the RED-before / GREEN-after guardrail for the convergence: it is
    /// RED while `default_workspace_id` ignores git, and GREEN once it resolves
    /// project identity first. It uses a live tmpdir because the convergence only
    /// fires when `.git` actually exists on disk for `resolve_project_identity`
    /// to detect (the static corpus rows use non-existent paths by design).
    #[test]
    fn default_workspace_id_converges_to_git_aware_for_same_project() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("myrepo");
        let repo_git = repo_root.join(".git");
        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::write(repo_root.join("CLAUDE.md"), "# repo").expect("project marker");

        let repo_path = repo_root.to_string_lossy().to_string();

        // The git-aware key the session/routing reducers derive: resolve identity
        // (project_id = .git common_dir, project_path = repo_root) then hash.
        let identity = resolve_project_identity(&repo_path).expect("repo identity");
        let git_aware_key = workspace_id(&identity.project_id, &identity.project_path);

        // The project-list key: default_workspace_id(repo_path). Post-STEP-1 this
        // must internally resolve git identity and produce the SAME key.
        let default_key = default_workspace_id(&repo_path);

        assert_eq!(
            default_key, git_aware_key,
            "C2-Phase2 convergence: default_workspace_id(repo_path) must equal the \
             git-aware workspace_id(common_dir, repo_path) for the same git project"
        );
    }

    #[test]
    fn workspace_id_is_stable_across_worktrees() {
        let temp_dir = tempfile::tempdir().expect("temp dir");
        let repo_root = temp_dir.path().join("assistant-ui");
        let repo_git = repo_root.join(".git");
        let docs_dir = repo_root.join("apps").join("docs");
        let src_dir = docs_dir.join("src");

        std::fs::create_dir_all(&src_dir).expect("create repo dirs");
        std::fs::create_dir_all(&repo_git).expect("create git dir");
        std::fs::write(docs_dir.join("package.json"), "{}").expect("package marker");
        std::fs::write(src_dir.join("index.ts"), "export {};").expect("file");

        let worktree_root = temp_dir.path().join("assistant-ui-wt");
        let worktree_docs = worktree_root.join("apps").join("docs");
        std::fs::create_dir_all(worktree_docs.join("src")).expect("create worktree dirs");
        std::fs::write(worktree_docs.join("package.json"), "{}").expect("package marker");
        std::fs::write(worktree_docs.join("src").join("index.ts"), "export {};").expect("file");

        let worktree_gitdir = repo_git.join("worktrees").join("feat-docs");
        std::fs::create_dir_all(&worktree_gitdir).expect("create gitdir");
        std::fs::write(worktree_gitdir.join("commondir"), "../..").expect("commondir");
        std::fs::write(
            worktree_root.join(".git"),
            format!("gitdir: {}\n", worktree_gitdir.to_string_lossy()),
        )
        .expect("git file");

        let repo_identity =
            resolve_project_identity(src_dir.join("index.ts").to_string_lossy().as_ref())
                .expect("repo identity");
        let worktree_identity = resolve_project_identity(
            worktree_docs
                .join("src")
                .join("index.ts")
                .to_string_lossy()
                .as_ref(),
        )
        .expect("worktree identity");

        assert_eq!(repo_identity.project_id, worktree_identity.project_id);
        assert_eq!(repo_identity.project_path, worktree_identity.project_path);

        let repo_workspace = workspace_id(&repo_identity.project_id, &repo_identity.project_path);
        let worktree_workspace = workspace_id(
            &worktree_identity.project_id,
            &worktree_identity.project_path,
        );

        assert_eq!(repo_workspace, worktree_workspace);
    }
}

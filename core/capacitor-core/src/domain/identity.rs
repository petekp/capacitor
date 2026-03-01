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
pub fn display_name(project_path: &str) -> String {
    project_path
        .split('/')
        .rfind(|part| !part.is_empty())
        .unwrap_or(project_path)
        .to_string()
}

#[must_use]
pub fn normalize_path_for_matching(path: &str) -> String {
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
pub fn normalize_path_for_comparison(path: &str) -> String {
    let resolved = resolve_symlinks(path);
    normalize_path_for_matching(&resolved)
}

#[must_use]
pub fn default_workspace_id(project_path: &str) -> String {
    workspace_id(project_path, project_path)
}

#[must_use]
pub fn workspace_id(project_id: &str, project_path: &str) -> String {
    let project_id = canonicalize_path(Path::new(project_id));
    let project_path = canonicalize_path(Path::new(project_path));
    let relative = workspace_relative_path(&project_id, &project_path);
    let source = format!("{}|{}", project_id.to_string_lossy(), relative);

    #[cfg(target_os = "macos")]
    let source = source.to_lowercase();

    format!("{:x}", md5::compute(source))
}

pub fn resolve_project_identity(path: &str) -> Option<ProjectIdentity> {
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

fn resolve_symlinks(path: &str) -> String {
    let path_obj = Path::new(path);
    if path_obj.exists() {
        if let Ok(canonical) = path_obj.canonicalize() {
            return canonical.to_string_lossy().to_string();
        }
    }

    path.to_string()
}

fn path_to_string(path: &Path) -> String {
    path.to_string_lossy().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_path_trims_trailing_slashes() {
        assert_eq!(normalize_path_for_matching("/repo/"), "/repo");
        assert_eq!(normalize_path_for_matching("/repo//"), "/repo");
        assert_eq!(normalize_path_for_matching("/"), "/");
    }

    #[test]
    fn workspace_id_is_stable_for_case_changes() {
        let first = workspace_id("/Users/Pete/Code/Repo/.git", "/Users/Pete/Code/Repo");
        let second = workspace_id("/users/pete/code/repo/.git", "/users/pete/code/repo");
        assert_eq!(first, second);
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

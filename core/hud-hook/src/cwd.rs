//! Shell CWD tracking for ambient project awareness.
//!
//! Called by shell precmd hooks to report the current working directory.
//! Sends shell CWD events to the canonical core runtime.
//!
//! ## Usage
//!
//! ```bash
//! hud-hook cwd /path/to/project 12345 /dev/ttys003
//! ```
//!
//! ## Performance
//!
//! Target: < 15ms total execution time.
//! The shell spawns this in the background, so users never wait.

use capacitor_core::{domain::TmuxPaneInfo, runtime_types::ParentApp};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};
use thiserror::Error;

#[derive(Error, Debug)]
pub enum CwdError {
    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Runtime unavailable: {0}")]
    RuntimeUnavailable(String),
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    #[serde(default)]
    pub parent_app: ParentApp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_client_tty: Option<String>,
    pub updated_at: DateTime<Utc>,
}

impl ShellEntry {
    fn new(cwd: String, tty: String, parent_app: ParentApp) -> Self {
        let (tmux_session, tmux_client_tty) = if std::env::var("TMUX").is_ok() {
            detect_tmux_context().map_or((None, None), |(s, t)| (Some(s), Some(t)))
        } else {
            (None, None)
        };

        Self {
            cwd,
            tty,
            parent_app,
            tmux_session,
            tmux_client_tty,
            updated_at: Utc::now(),
        }
    }
}

// MARK: - Public API

pub fn run(path: &str, pid: u32, tty: &str) -> Result<(), CwdError> {
    let normalized_path = normalize_path(path);
    let parent_app = detect_parent_app(pid);
    let resolved_tty = resolve_tty(tty)?;
    let entry = ShellEntry::new(normalized_path.clone(), resolved_tty.clone(), parent_app);
    let proc_start = detect_proc_start(pid);
    let tmux_pane = detect_tmux_pane();
    let tmux_panes = detect_tmux_pane_inventory();

    if !crate::runtime_client::runtime_enabled() {
        return Err(CwdError::RuntimeUnavailable(
            "Core runtime disabled".to_string(),
        ));
    }

    match crate::runtime_client::send_shell_cwd_event(
        pid,
        &normalized_path,
        &resolved_tty,
        parent_app,
        entry.tmux_session.clone(),
        entry.tmux_client_tty.clone(),
        proc_start,
        tmux_pane,
        tmux_panes,
    ) {
        Ok(()) => Ok(()),
        Err(err) => Err(CwdError::RuntimeUnavailable(err)),
    }
}

fn normalize_path(path: &str) -> String {
    let normalized = if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    };

    let normalized_path = Path::new(&normalized);
    if !normalized_path.is_absolute() {
        return normalized;
    }

    let canonical = match std::fs::canonicalize(normalized_path) {
        Ok(path) => path,
        Err(_) => return normalized,
    };

    merge_canonical_case(normalized_path, &canonical)
}

fn merge_canonical_case(original: &Path, _canonical: &Path) -> String {
    let original_parts = path_components(original);

    let mut real_path = PathBuf::new();
    if original.is_absolute() {
        real_path.push("/");
    }

    for part in &original_parts {
        if part == "/" {
            continue;
        }
        if part == "." || part == ".." {
            real_path.push(part);
            continue;
        }

        let mut found_match = false;
        if let Ok(entries) = std::fs::read_dir(&real_path) {
            for entry in entries.filter_map(Result::ok) {
                if let Ok(name) = entry.file_name().into_string() {
                    if name.eq_ignore_ascii_case(part) {
                        real_path.push(name);
                        found_match = true;
                        break;
                    }
                }
            }
        }

        if !found_match {
            real_path.push(part);
        }
    }

    let result = real_path.to_string_lossy().to_string();
    if result.is_empty() {
        "/".to_string()
    } else {
        result
    }
}

fn path_components(path: &Path) -> Vec<String> {
    path.components()
        .filter_map(|component| match component {
            Component::Normal(part) => Some(part.to_string_lossy().to_string()),
            _ => None,
        })
        .collect()
}

fn resolve_tty(tty: &str) -> Result<String, CwdError> {
    let provided = tty.trim();
    if !provided.is_empty() {
        return Ok(provided.to_string());
    }

    if let Ok(env_tty) = std::env::var("TTY") {
        let env_tty = env_tty.trim();
        if !env_tty.is_empty() {
            return Ok(env_tty.to_string());
        }
    }

    let fallback = std::process::Command::new("tty")
        .output()
        .ok()
        .and_then(|out| {
            if out.status.success() {
                Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
            } else {
                None
            }
        })
        .filter(|value| !value.is_empty());

    match fallback {
        Some(value) => Ok(value),
        None => Err(CwdError::RuntimeUnavailable(
            "Missing TTY for shell cwd event".to_string(),
        )),
    }
}

fn detect_parent_app(_pid: u32) -> ParentApp {
    if let Ok(term_program) = std::env::var("TERM_PROGRAM") {
        let normalized = term_program.to_lowercase();
        match normalized.as_str() {
            "iterm.app" | "iterm2" => return ParentApp::ITerm,
            "apple_terminal" | "terminal.app" | "terminal" => return ParentApp::Terminal,
            "warpterminal" | "warp" => return ParentApp::Warp,
            "ghostty" => return ParentApp::Ghostty,
            "vscode" => return ParentApp::VSCode,
            "vscode-insiders" => return ParentApp::VSCodeInsiders,
            "cursor" => return ParentApp::Cursor,
            "zed" => return ParentApp::Zed,
            _ => {}
        }
    }

    if let Ok(term) = std::env::var("TERM") {
        let normalized = term.to_lowercase();
        if normalized.contains("kitty") {
            return ParentApp::Kitty;
        }
        if normalized.contains("alacritty") {
            return ParentApp::Alacritty;
        }
    }

    if std::env::var("TMUX").is_ok() {
        return ParentApp::Tmux;
    }

    ParentApp::Unknown
}

fn detect_tmux_context() -> Option<(String, String)> {
    if std::env::var("TMUX").is_err() {
        return None;
    }

    use std::time::Duration;
    use wait_timeout::ChildExt;

    let mut child = std::process::Command::new("tmux")
        .args(["display-message", "-p", "#S\t#{client_tty}"])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;

    let timeout = Duration::from_millis(500);
    match child.wait_timeout(timeout).ok()? {
        Some(status) if status.success() => {
            let output = child.wait_with_output().ok()?;
            let output_str = String::from_utf8_lossy(&output.stdout);
            let trimmed = output_str.trim();
            let mut parts = trimmed.splitn(2, '\t');
            match (parts.next(), parts.next()) {
                (Some(session), Some(tty)) if !session.is_empty() && !tty.is_empty() => {
                    Some((session.to_string(), tty.to_string()))
                }
                _ => None,
            }
        }
        Some(_) => None,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            None
        }
    }
}

fn detect_tmux_pane() -> Option<String> {
    std::env::var("TMUX_PANE")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

fn detect_tmux_pane_inventory() -> Vec<TmuxPaneInfo> {
    if std::env::var("TMUX").is_err() {
        return Vec::new();
    }

    use std::time::Duration;
    use wait_timeout::ChildExt;

    let mut child = match std::process::Command::new("tmux")
        .args([
            "list-panes",
            "-a",
            "-F",
            "#S\t#{pane_id}\t#{pane_current_path}\t#{session_attached}",
        ])
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return Vec::new(),
    };

    let timeout = Duration::from_millis(500);
    match child.wait_timeout(timeout).ok().flatten() {
        Some(status) if status.success() => {
            let output = match child.wait_with_output() {
                Ok(output) => output,
                Err(_) => return Vec::new(),
            };
            parse_tmux_pane_inventory_output(&String::from_utf8_lossy(&output.stdout))
        }
        Some(_) => Vec::new(),
        None => {
            let _ = child.kill();
            let _ = child.wait();
            Vec::new()
        }
    }
}

fn parse_tmux_pane_inventory_output(output: &str) -> Vec<TmuxPaneInfo> {
    output
        .lines()
        .filter_map(|line| {
            let mut parts = line.splitn(4, '\t');
            let session_name = parts.next()?.trim();
            let pane_id = parts.next()?.trim();
            let pane_path = parts.next()?.trim();
            let session_attached = parts.next().unwrap_or("0").trim();
            if session_name.is_empty() || pane_id.is_empty() || pane_path.is_empty() {
                return None;
            }
            Some(TmuxPaneInfo {
                session_name: session_name.to_string(),
                pane_id: pane_id.to_string(),
                pane_path: normalize_path(pane_path),
                session_attached: session_attached != "0",
            })
        })
        .collect()
}

use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

fn detect_proc_start(pid: u32) -> Option<u64> {
    let mut sys = System::new();
    let sys_pid = Pid::from(pid as usize);
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&[sys_pid]),
        true,
        ProcessRefreshKind::nothing(),
    );
    sys.process(sys_pid).map(|process| process.start_time())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;
    use std::sync::{Mutex, MutexGuard};
    use std::time::{SystemTime, UNIX_EPOCH};

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        _lock: MutexGuard<'static, ()>,
        tmux: Option<String>,
        term_program: Option<String>,
        term: Option<String>,
    }

    impl EnvGuard {
        fn acquire() -> Self {
            let lock = ENV_LOCK.lock().expect("env lock");
            Self {
                _lock: lock,
                tmux: std::env::var("TMUX").ok(),
                term_program: std::env::var("TERM_PROGRAM").ok(),
                term: std::env::var("TERM").ok(),
            }
        }

        fn set_var(&self, key: &str, value: &str) {
            std::env::set_var(key, value);
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            match &self.tmux {
                Some(value) => std::env::set_var("TMUX", value),
                None => std::env::remove_var("TMUX"),
            }
            match &self.term_program {
                Some(value) => std::env::set_var("TERM_PROGRAM", value),
                None => std::env::remove_var("TERM_PROGRAM"),
            }
            match &self.term {
                Some(value) => std::env::set_var("TERM", value),
                None => std::env::remove_var("TERM"),
            }
        }
    }

    #[test]
    fn test_detect_parent_app_preserves_host_when_tmux_set() {
        let guard = EnvGuard::acquire();
        guard.set_var("TMUX", "/tmp/tmux-123");
        guard.set_var("TERM_PROGRAM", "cursor");

        let app = detect_parent_app(12345);
        assert_eq!(app, ParentApp::Cursor);
    }

    fn unique_temp_path(suffix: &str) -> PathBuf {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("current time should be after epoch")
            .as_nanos();
        std::env::temp_dir().join(format!("hud-hook-cwd-{suffix}-{nanos}"))
    }

    #[test]
    fn test_normalize_path_canonicalizes_existing_case_variants() {
        let root = unique_temp_path("canonicalize");
        let actual = root.join("CoDe").join("openclaw");
        fs::create_dir_all(&actual).expect("create mixed-case directory tree");

        let alias = root.join("code").join("openclaw");
        let alias_string = alias.to_string_lossy().to_string();
        let normalized = normalize_path(&alias_string);

        if alias.exists() {
            assert_eq!(
                normalized,
                actual.to_string_lossy().to_string(),
                "existing case variants should canonicalize to a stable path identity",
            );
        } else {
            assert_eq!(
                normalized, alias_string,
                "on case-sensitive filesystems, unknown-case aliases must fall back to raw path",
            );
        }

        fs::remove_dir_all(&root).expect("cleanup mixed-case directory tree");
    }

    #[test]
    fn test_parse_tmux_pane_inventory_output_normalizes_rows() {
        let output = "\
dev\t%0\t/Users/Pete/Code/Pete-2025/\t1\n\
dev\t%1\t/Users/Pete/Code/AUI/mcp-app-studio-starter/\t0\n\
\t%2\t/missing/session\t1\n";

        let panes = parse_tmux_pane_inventory_output(output);

        assert_eq!(panes.len(), 2);
        assert_eq!(panes[0].session_name, "dev");
        assert_eq!(panes[0].pane_id, "%0");
        assert_eq!(panes[0].pane_path, "/Users/Pete/Code/Pete-2025");
        assert!(panes[0].session_attached);
        assert_eq!(panes[1].pane_id, "%1");
        assert_eq!(
            panes[1].pane_path,
            "/Users/Pete/Code/AUI/mcp-app-studio-starter"
        );
        assert!(!panes[1].session_attached);
    }
}

//! Shell CWD tracking for ambient project awareness.
//!
//! Called by shell precmd hooks to report the current working directory.
//! Updates `~/.capacitor/shell-cwd.json` with current shell state and
//! appends to `~/.capacitor/shell-history.jsonl` when CWD changes.
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

use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use rand::Rng;
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;
use thiserror::Error;

const HISTORY_RETENTION_DAYS: i64 = 30;
const CLEANUP_PROBABILITY: f64 = 0.01;

#[derive(Error, Debug)]
pub enum CwdError {
    #[error("Home directory not found")]
    NoHomeDir,

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),

    #[error("Failed to persist temp file: {0}")]
    Persist(#[from] tempfile::PersistError),
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ShellCwdState {
    pub version: u32,
    pub shells: HashMap<String, ShellEntry>,
}

impl Default for ShellCwdState {
    fn default() -> Self {
        Self {
            version: 1,
            shells: HashMap::new(),
        }
    }
}

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
pub struct ShellEntry {
    pub cwd: String,
    pub tty: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_app: Option<String>,
    pub updated_at: DateTime<Utc>,
}

pub fn run(path: &str, pid: u32, tty: &str) -> Result<(), CwdError> {
    let state_dir = dirs::home_dir()
        .ok_or(CwdError::NoHomeDir)?
        .join(".capacitor");

    fs::create_dir_all(&state_dir)?;

    let cwd_path = state_dir.join("shell-cwd.json");
    let history_path = state_dir.join("shell-history.jsonl");

    // Normalize path: strip trailing slashes (except for root "/")
    let normalized_path = normalize_path(path);

    let mut state = load_state(&cwd_path)?;

    let previous_cwd = state.shells.get(&pid.to_string()).map(|e| e.cwd.clone());
    let cwd_changed = previous_cwd.as_deref() != Some(&normalized_path);

    let parent_app = detect_parent_app(pid);

    state.shells.insert(
        pid.to_string(),
        ShellEntry {
            cwd: normalized_path.clone(),
            tty: tty.to_string(),
            parent_app: parent_app.clone(),
            updated_at: Utc::now(),
        },
    );

    cleanup_dead_pids(&mut state);

    write_state_atomic(&cwd_path, &state)?;

    // History append is non-critical - log errors but don't fail the operation
    if cwd_changed {
        if let Err(e) = append_history(
            &history_path,
            &normalized_path,
            pid,
            tty,
            parent_app.as_deref(),
        ) {
            eprintln!("Warning: Failed to append history: {}", e);
        }
    }

    maybe_cleanup_history(&history_path);

    Ok(())
}

fn normalize_path(path: &str) -> String {
    if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    }
}

fn load_state(path: &Path) -> Result<ShellCwdState, CwdError> {
    if !path.exists() {
        return Ok(ShellCwdState::default());
    }

    let content = fs::read_to_string(path)?;

    if content.trim().is_empty() {
        return Ok(ShellCwdState::default());
    }

    match serde_json::from_str::<ShellCwdState>(&content) {
        Ok(state) if state.version == 1 => Ok(state),
        Ok(_) => Ok(ShellCwdState::default()),
        Err(_) => Ok(ShellCwdState::default()),
    }
}

fn write_state_atomic(path: &Path, state: &ShellCwdState) -> Result<(), CwdError> {
    let parent_dir = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "No parent directory"))?;

    let temp_file = NamedTempFile::new_in(parent_dir)?;
    serde_json::to_writer_pretty(&temp_file, state)?;
    temp_file.as_file().sync_all()?;
    temp_file.persist(path)?;

    Ok(())
}

fn cleanup_dead_pids(state: &mut ShellCwdState) {
    state
        .shells
        .retain(|pid_str, _| pid_str.parse::<u32>().map(process_exists).unwrap_or(false));
}

fn process_exists(pid: u32) -> bool {
    unsafe { libc::kill(pid as i32, 0) == 0 }
}

fn append_history(
    path: &Path,
    cwd: &str,
    pid: u32,
    tty: &str,
    parent_app: Option<&str>,
) -> Result<(), CwdError> {
    let entry = serde_json::json!({
        "cwd": cwd,
        "pid": pid,
        "tty": tty,
        "parent_app": parent_app,
        "timestamp": Utc::now().to_rfc3339(),
    });

    let file = OpenOptions::new().create(true).append(true).open(path)?;

    let mut writer = BufWriter::new(file);
    writeln!(writer, "{}", entry)?;
    writer.flush()?;

    Ok(())
}

fn maybe_cleanup_history(path: &Path) {
    if rand::thread_rng().gen::<f64>() > CLEANUP_PROBABILITY {
        return;
    }

    if let Err(e) = cleanup_history(path, HISTORY_RETENTION_DAYS) {
        eprintln!("Warning: Failed to cleanup history: {}", e);
    }
}

fn cleanup_history(path: &Path, retention_days: i64) -> Result<(), CwdError> {
    if !path.exists() {
        return Ok(());
    }

    let cutoff = Utc::now() - Duration::days(retention_days);

    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);

    let mut kept_lines = Vec::new();
    let mut removed_count = 0;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        if let Ok(entry) = serde_json::from_str::<HistoryEntry>(&line) {
            if entry.timestamp >= cutoff {
                kept_lines.push(line);
            } else {
                removed_count += 1;
            }
        } else {
            kept_lines.push(line);
        }
    }

    if removed_count == 0 {
        return Ok(());
    }

    let parent_dir = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "No parent directory"))?;

    let temp_file = NamedTempFile::new_in(parent_dir)?;
    {
        let mut writer = BufWriter::new(&temp_file);
        for line in kept_lines {
            writeln!(writer, "{}", line)?;
        }
        writer.flush()?;
    }
    temp_file.as_file().sync_all()?;
    temp_file.persist(path)?;

    Ok(())
}

#[derive(Debug, Deserialize)]
struct HistoryEntry {
    timestamp: DateTime<Utc>,
}

const KNOWN_APPS: &[(&str, &str)] = &[
    // IDEs (check first - they spawn terminal processes)
    ("Cursor Helper", "cursor"),
    ("Cursor", "cursor"),
    ("Code Helper", "vscode"),
    ("Code - Insiders", "vscode-insiders"),
    ("Code", "vscode"),
    // Terminal emulators
    ("Ghostty", "ghostty"),
    ("iTerm2", "iterm2"),
    ("Terminal", "terminal"),
    ("Alacritty", "alacritty"),
    ("kitty", "kitty"),
    ("WarpTerminal", "warp"),
    ("Warp", "warp"),
    // Multiplexers
    ("tmux", "tmux"),
];

fn detect_parent_app(pid: u32) -> Option<String> {
    let mut current_pid = pid;

    for _ in 0..20 {
        let ppid = get_parent_pid(current_pid).ok()?;

        if ppid <= 1 {
            return None;
        }

        let name = get_process_name(ppid).ok()?;

        for (pattern, app_id) in KNOWN_APPS {
            if name.contains(pattern) {
                return Some(app_id.to_string());
            }
        }

        current_pid = ppid;
    }

    None
}

fn get_parent_pid(pid: u32) -> Result<u32, std::io::Error> {
    #[repr(C)]
    struct ProcBsdInfo {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
        // ... more fields we don't need
        _padding: [u8; 120],
    }

    const PROC_PIDTBSDINFO: i32 = 3;

    extern "C" {
        fn proc_pidinfo(
            pid: i32,
            flavor: i32,
            arg: u64,
            buffer: *mut libc::c_void,
            buffersize: i32,
        ) -> i32;
    }

    let mut info: ProcBsdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<ProcBsdInfo>() as i32;

    let result = unsafe {
        proc_pidinfo(
            pid as i32,
            PROC_PIDTBSDINFO,
            0,
            &mut info as *mut _ as *mut libc::c_void,
            size,
        )
    };

    if result <= 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "Failed to get process info",
        ));
    }

    Ok(info.pbi_ppid)
}

fn get_process_name(pid: u32) -> Result<String, std::io::Error> {
    const PROC_PIDPATHINFO_MAXSIZE: usize = 4096;

    extern "C" {
        fn proc_name(pid: i32, buffer: *mut libc::c_char, buffersize: u32) -> i32;
    }

    let mut buffer = vec![0i8; PROC_PIDPATHINFO_MAXSIZE];
    let result = unsafe { proc_name(pid as i32, buffer.as_mut_ptr(), buffer.len() as u32) };

    if result <= 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "Failed to get process name",
        ));
    }

    let name = unsafe {
        std::ffi::CStr::from_ptr(buffer.as_ptr())
            .to_string_lossy()
            .into_owned()
    };

    Ok(name)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    #[test]
    fn test_load_state_creates_default_for_missing_file() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("nonexistent.json");

        let state = load_state(&path).unwrap();

        assert_eq!(state.version, 1);
        assert!(state.shells.is_empty());
    }

    #[test]
    fn test_load_state_handles_empty_file() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("empty.json");
        fs::write(&path, "").unwrap();

        let state = load_state(&path).unwrap();

        assert_eq!(state.version, 1);
        assert!(state.shells.is_empty());
    }

    #[test]
    fn test_load_state_handles_corrupt_json() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("corrupt.json");
        fs::write(&path, "{invalid json}").unwrap();

        let state = load_state(&path).unwrap();

        assert_eq!(state.version, 1);
        assert!(state.shells.is_empty());
    }

    #[test]
    fn test_write_state_atomic_creates_valid_json() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("state.json");

        let mut state = ShellCwdState::default();
        state.shells.insert(
            "12345".to_string(),
            ShellEntry {
                cwd: "/test/path".to_string(),
                tty: "/dev/ttys000".to_string(),
                parent_app: Some("cursor".to_string()),
                updated_at: Utc::now(),
            },
        );

        write_state_atomic(&path, &state).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let loaded: ShellCwdState = serde_json::from_str(&content).unwrap();

        assert_eq!(loaded.version, 1);
        assert_eq!(loaded.shells.len(), 1);
        assert_eq!(loaded.shells["12345"].cwd, "/test/path");
        assert_eq!(
            loaded.shells["12345"].parent_app,
            Some("cursor".to_string())
        );
    }

    #[test]
    fn test_append_history_creates_jsonl() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("history.jsonl");

        append_history(&path, "/path/a", 12345, "/dev/ttys000", Some("cursor")).unwrap();
        append_history(&path, "/path/b", 12345, "/dev/ttys000", None).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = content.lines().collect();

        assert_eq!(lines.len(), 2);

        let entry1: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(entry1["cwd"], "/path/a");
        assert_eq!(entry1["parent_app"], "cursor");

        let entry2: serde_json::Value = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(entry2["cwd"], "/path/b");
        assert!(entry2["parent_app"].is_null());
    }

    #[test]
    fn test_process_exists_returns_true_for_self() {
        let pid = std::process::id();
        assert!(process_exists(pid));
    }

    #[test]
    fn test_process_exists_returns_false_for_invalid_pid() {
        assert!(!process_exists(999999999));
    }

    #[test]
    fn test_cleanup_dead_pids_removes_nonexistent() {
        let mut state = ShellCwdState::default();

        state.shells.insert(
            "999999999".to_string(),
            ShellEntry {
                cwd: "/old".to_string(),
                tty: "/dev/ttys999".to_string(),
                parent_app: None,
                updated_at: Utc::now(),
            },
        );

        let current_pid = std::process::id().to_string();
        state.shells.insert(
            current_pid.clone(),
            ShellEntry {
                cwd: "/current".to_string(),
                tty: "/dev/ttys000".to_string(),
                parent_app: None,
                updated_at: Utc::now(),
            },
        );

        cleanup_dead_pids(&mut state);

        assert!(!state.shells.contains_key("999999999"));
        assert!(state.shells.contains_key(&current_pid));
    }

    #[test]
    fn test_normalize_path_strips_trailing_slash() {
        assert_eq!(normalize_path("/foo/bar/"), "/foo/bar");
        assert_eq!(normalize_path("/foo/bar"), "/foo/bar");
        assert_eq!(normalize_path("/"), "/");
        assert_eq!(normalize_path("/foo/"), "/foo");
    }

    #[test]
    fn test_state_roundtrip() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("state.json");

        let mut original = ShellCwdState::default();
        original.shells.insert(
            "12345".to_string(),
            ShellEntry {
                cwd: "/test".to_string(),
                tty: "/dev/ttys000".to_string(),
                parent_app: Some("iterm2".to_string()),
                updated_at: Utc::now(),
            },
        );

        write_state_atomic(&path, &original).unwrap();
        let loaded = load_state(&path).unwrap();

        assert_eq!(loaded.version, original.version);
        assert_eq!(loaded.shells.len(), original.shells.len());
        assert_eq!(loaded.shells["12345"].cwd, original.shells["12345"].cwd);
        assert_eq!(
            loaded.shells["12345"].parent_app,
            original.shells["12345"].parent_app
        );
    }

    #[test]
    fn test_cleanup_history_removes_old_entries() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("history.jsonl");

        let now = Utc::now();
        let old_time = now - chrono::Duration::days(60);
        let recent_time = now - chrono::Duration::days(10);

        let mut content = String::new();
        content.push_str(&format!(
            "{{\"cwd\":\"/old\",\"pid\":1,\"tty\":\"/dev/ttys000\",\"parent_app\":null,\"timestamp\":\"{}\"}}\n",
            old_time.to_rfc3339()
        ));
        content.push_str(&format!(
            "{{\"cwd\":\"/recent\",\"pid\":2,\"tty\":\"/dev/ttys001\",\"parent_app\":null,\"timestamp\":\"{}\"}}\n",
            recent_time.to_rfc3339()
        ));
        content.push_str(&format!(
            "{{\"cwd\":\"/new\",\"pid\":3,\"tty\":\"/dev/ttys002\",\"parent_app\":null,\"timestamp\":\"{}\"}}\n",
            now.to_rfc3339()
        ));

        fs::write(&path, content).unwrap();

        cleanup_history(&path, 30).unwrap();

        let result = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = result.lines().collect();

        assert_eq!(lines.len(), 2);
        assert!(lines[0].contains("/recent"));
        assert!(lines[1].contains("/new"));
    }

    #[test]
    fn test_cleanup_history_handles_missing_file() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("nonexistent.jsonl");

        let result = cleanup_history(&path, 30);
        assert!(result.is_ok());
    }

    #[test]
    fn test_paths_with_spaces() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("state.json");

        let mut state = ShellCwdState::default();
        state.shells.insert(
            "12345".to_string(),
            ShellEntry {
                cwd: "/Users/test/My Documents/Project Name".to_string(),
                tty: "/dev/ttys000".to_string(),
                parent_app: None,
                updated_at: Utc::now(),
            },
        );

        write_state_atomic(&path, &state).unwrap();
        let loaded = load_state(&path).unwrap();

        assert_eq!(
            loaded.shells["12345"].cwd,
            "/Users/test/My Documents/Project Name"
        );
    }

    #[test]
    fn test_paths_with_special_characters() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("state.json");

        let mut state = ShellCwdState::default();
        state.shells.insert(
            "12345".to_string(),
            ShellEntry {
                cwd: r#"/path/with "quotes" and \backslashes\ and $dollars"#.to_string(),
                tty: "/dev/ttys000".to_string(),
                parent_app: None,
                updated_at: Utc::now(),
            },
        );

        write_state_atomic(&path, &state).unwrap();
        let loaded = load_state(&path).unwrap();

        assert_eq!(
            loaded.shells["12345"].cwd,
            r#"/path/with "quotes" and \backslashes\ and $dollars"#
        );
    }

    #[test]
    fn test_paths_with_unicode() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("state.json");

        let mut state = ShellCwdState::default();
        state.shells.insert(
            "12345".to_string(),
            ShellEntry {
                cwd: "/Users/日本語/项目/مشروع/🚀".to_string(),
                tty: "/dev/ttys000".to_string(),
                parent_app: None,
                updated_at: Utc::now(),
            },
        );

        write_state_atomic(&path, &state).unwrap();
        let loaded = load_state(&path).unwrap();

        assert_eq!(loaded.shells["12345"].cwd, "/Users/日本語/项目/مشروع/🚀");
    }

    #[test]
    fn test_history_with_special_paths() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("history.jsonl");

        let special_path = r#"/path/with "quotes" and spaces/日本語"#;
        append_history(&path, special_path, 12345, "/dev/ttys000", None).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let entry: serde_json::Value = serde_json::from_str(content.trim()).unwrap();

        assert_eq!(entry["cwd"], special_path);
    }

    #[test]
    fn test_normalize_path_preserves_special_chars() {
        assert_eq!(normalize_path("/path/with spaces/"), "/path/with spaces");
        assert_eq!(normalize_path("/path/日本語/"), "/path/日本語");
        assert_eq!(normalize_path(r#"/path/"quotes"/"#), r#"/path/"quotes""#);
    }
}

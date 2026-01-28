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

use fs_err as fs;
use fs_err::OpenOptions;
use std::collections::HashMap;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::Path;

use chrono::{DateTime, Duration, Utc};
use hud_core::ParentApp;
use rand::Rng;
use serde::{Deserialize, Serialize};
use tempfile::NamedTempFile;
use thiserror::Error;

const HISTORY_RETENTION_DAYS: i64 = 30;
const CLEANUP_PROBABILITY: f64 = 0.01;
const MAX_PARENT_CHAIN_DEPTH: usize = 20;

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
        let (tmux_session, tmux_client_tty) = if parent_app == ParentApp::Tmux {
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
    let state_dir = get_state_dir()?;
    fs::create_dir_all(&state_dir)?;

    let cwd_path = state_dir.join("shell-cwd.json");
    let history_path = state_dir.join("shell-history.jsonl");

    let normalized_path = normalize_path(path);
    let mut state = load_state(&cwd_path)?;

    let cwd_changed = has_cwd_changed(&state, pid, &normalized_path);
    let parent_app = detect_parent_app(pid);

    state.shells.insert(
        pid.to_string(),
        ShellEntry::new(normalized_path.clone(), tty.to_string(), parent_app),
    );

    cleanup_dead_pids(&mut state);
    write_state_atomic(&cwd_path, &state)?;

    if cwd_changed {
        log_history_append_error(append_history(
            &history_path,
            &normalized_path,
            pid,
            tty,
            parent_app,
        ));
    }

    maybe_cleanup_history(&history_path);
    Ok(())
}

// MARK: - State Directory

fn get_state_dir() -> Result<std::path::PathBuf, CwdError> {
    dirs::home_dir()
        .ok_or(CwdError::NoHomeDir)
        .map(|h| h.join(".capacitor"))
}

// MARK: - Path Normalization

fn normalize_path(path: &str) -> String {
    if path == "/" {
        "/".to_string()
    } else {
        path.trim_end_matches('/').to_string()
    }
}

// MARK: - State Management

fn has_cwd_changed(state: &ShellCwdState, pid: u32, new_cwd: &str) -> bool {
    state.shells.get(&pid.to_string()).map(|e| e.cwd.as_str()) != Some(new_cwd)
}

fn load_state(path: &Path) -> Result<ShellCwdState, CwdError> {
    if !path.exists() {
        return Ok(ShellCwdState::default());
    }

    let content = fs::read_to_string(path)?;
    if content.trim().is_empty() {
        return Ok(ShellCwdState::default());
    }

    Ok(serde_json::from_str::<ShellCwdState>(&content)
        .ok()
        .filter(|s| s.version == 1)
        .unwrap_or_default())
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
    // SAFETY: kill(pid, 0) is a standard POSIX liveness check that sends no signal.
    // Returns 0 if the process exists, -1 with ESRCH if not.
    #[allow(unsafe_code)]
    unsafe {
        libc::kill(pid as i32, 0) == 0
    }
}

// MARK: - History Management

fn append_history(
    path: &Path,
    cwd: &str,
    pid: u32,
    tty: &str,
    parent_app: ParentApp,
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

fn log_history_append_error(result: Result<(), CwdError>) {
    if let Err(e) = result {
        tracing::warn!(error = %e, "Failed to append history");
    }
}

fn maybe_cleanup_history(path: &Path) {
    if rand::thread_rng().gen::<f64>() > CLEANUP_PROBABILITY {
        return;
    }

    if let Err(e) = cleanup_history(path, HISTORY_RETENTION_DAYS) {
        tracing::warn!(error = %e, "Failed to cleanup history");
    }
}

fn cleanup_history(path: &Path, retention_days: i64) -> Result<(), CwdError> {
    if !path.exists() {
        return Ok(());
    }

    let cutoff = Utc::now() - Duration::days(retention_days);
    let (kept_lines, removed_count) = filter_history_entries(path, cutoff)?;

    if removed_count == 0 {
        return Ok(());
    }

    write_history_atomic(path, &kept_lines)
}

fn filter_history_entries(
    path: &Path,
    cutoff: DateTime<Utc>,
) -> Result<(Vec<String>, usize), CwdError> {
    let file = fs::File::open(path)?;
    let reader = BufReader::new(file);

    let mut kept_lines = Vec::new();
    let mut removed_count = 0;

    for line in reader.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }

        let should_keep = serde_json::from_str::<HistoryEntry>(&line)
            .map(|e| e.timestamp >= cutoff)
            .unwrap_or(true);

        if should_keep {
            kept_lines.push(line);
        } else {
            removed_count += 1;
        }
    }

    Ok((kept_lines, removed_count))
}

fn write_history_atomic(path: &Path, lines: &[String]) -> Result<(), CwdError> {
    let parent_dir = path
        .parent()
        .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "No parent directory"))?;

    let temp_file = NamedTempFile::new_in(parent_dir)?;
    {
        let mut writer = BufWriter::new(&temp_file);
        for line in lines {
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

// MARK: - Tmux Context Detection

/// Captures the tmux session name and the TTY of the terminal hosting tmux.
/// The host TTY is needed because the shell's TTY is a tmux pseudo-terminal,
/// not the actual terminal window we need to activate.
fn detect_tmux_context() -> Option<(String, String)> {
    let session_name = run_tmux_command(&["display-message", "-p", "#S"])?;
    if session_name.is_empty() {
        return None;
    }

    let client_tty = run_tmux_command(&["list-clients", "-F", "#{client_tty}"])?
        .lines()
        .next()?
        .to_string();

    if client_tty.is_empty() {
        return None;
    }

    Some((session_name, client_tty))
}

fn run_tmux_command(args: &[&str]) -> Option<String> {
    use std::process::Command;

    let output = Command::new("tmux").args(args).output().ok()?;

    if !output.status.success() {
        return None;
    }

    String::from_utf8(output.stdout)
        .ok()
        .map(|s| s.trim().to_string())
}

// MARK: - Parent App Detection

const KNOWN_APPS: &[(&str, ParentApp)] = &[
    // IDEs (check first - they spawn terminal processes)
    ("Cursor Helper", ParentApp::Cursor),
    ("Cursor", ParentApp::Cursor),
    ("Code Helper", ParentApp::VSCode),
    ("Code - Insiders", ParentApp::VSCodeInsiders),
    ("Code", ParentApp::VSCode),
    ("Zed", ParentApp::Zed),
    // Terminal emulators
    ("ghostty", ParentApp::Ghostty),
    ("Ghostty", ParentApp::Ghostty),
    ("iTerm2", ParentApp::ITerm),
    ("Terminal", ParentApp::Terminal),
    ("Alacritty", ParentApp::Alacritty),
    ("kitty", ParentApp::Kitty),
    ("WarpTerminal", ParentApp::Warp),
    ("Warp", ParentApp::Warp),
    // Multiplexers
    ("tmux", ParentApp::Tmux),
];

fn detect_parent_app(pid: u32) -> ParentApp {
    let mut current_pid = pid;

    for _ in 0..MAX_PARENT_CHAIN_DEPTH {
        let ppid = match get_parent_pid(current_pid) {
            Ok(p) => p,
            Err(_) => return ParentApp::Unknown,
        };
        if ppid <= 1 {
            return ParentApp::Unknown;
        }

        if let Some(app) = identify_app_from_pid(ppid) {
            return app;
        }

        current_pid = ppid;
    }

    ParentApp::Unknown
}

fn identify_app_from_pid(pid: u32) -> Option<ParentApp> {
    let name = get_process_name(pid).ok()?;

    KNOWN_APPS
        .iter()
        .find(|(pattern, _)| name.contains(pattern))
        .map(|(_, app)| *app)
}

// MARK: - macOS Process APIs

fn get_parent_pid(pid: u32) -> Result<u32, std::io::Error> {
    #[repr(C)]
    struct ProcBsdInfo {
        pbi_flags: u32,
        pbi_status: u32,
        pbi_xstatus: u32,
        pbi_pid: u32,
        pbi_ppid: u32,
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

    // SAFETY: ProcBsdInfo is a #[repr(C)] struct of primitive types.
    // Zeroing is safe because all bit patterns are valid for the numeric fields.
    #[allow(unsafe_code)]
    let mut info: ProcBsdInfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<ProcBsdInfo>() as i32;

    // SAFETY: proc_pidinfo is a macOS system call that fills the buffer with process info.
    // We pass a properly-sized buffer and check the return value before using the data.
    #[allow(unsafe_code)]
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
    // SAFETY: proc_name is a macOS system call that writes a null-terminated C string.
    // We provide a buffer large enough (4096 bytes) and check result > 0 before use.
    #[allow(unsafe_code)]
    let result = unsafe { proc_name(pid as i32, buffer.as_mut_ptr(), buffer.len() as u32) };

    if result <= 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::NotFound,
            "Failed to get process name",
        ));
    }

    // SAFETY: proc_name guarantees null-termination when result > 0.
    // The buffer was initialized to zeros, so even partial writes are safe.
    #[allow(unsafe_code)]
    let name = unsafe {
        std::ffi::CStr::from_ptr(buffer.as_ptr())
            .to_string_lossy()
            .into_owned()
    };

    Ok(name)
}

// MARK: - Tests

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn make_shell_entry(cwd: &str, tty: &str, parent_app: ParentApp) -> ShellEntry {
        ShellEntry {
            cwd: cwd.to_string(),
            tty: tty.to_string(),
            parent_app,
            tmux_session: None,
            tmux_client_tty: None,
            updated_at: Utc::now(),
        }
    }

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
            make_shell_entry("/test/path", "/dev/ttys000", ParentApp::Cursor),
        );

        write_state_atomic(&path, &state).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let loaded: ShellCwdState = serde_json::from_str(&content).unwrap();

        assert_eq!(loaded.version, 1);
        assert_eq!(loaded.shells.len(), 1);
        assert_eq!(loaded.shells["12345"].cwd, "/test/path");
        assert_eq!(loaded.shells["12345"].parent_app, ParentApp::Cursor);
    }

    #[test]
    fn test_append_history_creates_jsonl() {
        let temp = TempDir::new().unwrap();
        let path = temp.path().join("history.jsonl");

        append_history(&path, "/path/a", 12345, "/dev/ttys000", ParentApp::Cursor).unwrap();
        append_history(&path, "/path/b", 12345, "/dev/ttys000", ParentApp::Unknown).unwrap();

        let content = fs::read_to_string(&path).unwrap();
        let lines: Vec<&str> = content.lines().collect();

        assert_eq!(lines.len(), 2);

        let entry1: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
        assert_eq!(entry1["cwd"], "/path/a");
        assert_eq!(entry1["parent_app"], "cursor");

        let entry2: serde_json::Value = serde_json::from_str(lines[1]).unwrap();
        assert_eq!(entry2["cwd"], "/path/b");
        assert_eq!(entry2["parent_app"], "unknown");
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
            make_shell_entry("/old", "/dev/ttys999", ParentApp::Unknown),
        );

        let current_pid = std::process::id().to_string();
        state.shells.insert(
            current_pid.clone(),
            make_shell_entry("/current", "/dev/ttys000", ParentApp::Unknown),
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
            make_shell_entry("/test", "/dev/ttys000", ParentApp::ITerm),
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
            make_shell_entry(
                "/Users/test/My Documents/Project Name",
                "/dev/ttys000",
                ParentApp::Unknown,
            ),
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
            make_shell_entry(
                r#"/path/with "quotes" and \backslashes\ and $dollars"#,
                "/dev/ttys000",
                ParentApp::Unknown,
            ),
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
            make_shell_entry(
                "/Users/日本語/项目/مشروع/🚀",
                "/dev/ttys000",
                ParentApp::Unknown,
            ),
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
        append_history(
            &path,
            special_path,
            12345,
            "/dev/ttys000",
            ParentApp::Unknown,
        )
        .unwrap();

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

    #[test]
    fn test_has_cwd_changed_detects_changes() {
        let mut state = ShellCwdState::default();
        state.shells.insert(
            "12345".to_string(),
            make_shell_entry("/old/path", "/dev/ttys000", ParentApp::Unknown),
        );

        assert!(has_cwd_changed(&state, 12345, "/new/path"));
        assert!(!has_cwd_changed(&state, 12345, "/old/path"));
        assert!(has_cwd_changed(&state, 99999, "/any/path"));
    }
}

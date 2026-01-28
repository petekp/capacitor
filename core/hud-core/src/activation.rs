//! Terminal activation resolution for the Swift UI.
//!
//! This module contains the pure decision logic for terminal activation.
//! Given the current shell state and tmux context, it determines what
//! action(s) Swift should take to activate the correct terminal.
//!
//! ## Design Principles
//!
//! 1. **Pure functions** — No side effects, no process spawning, no macOS APIs
//! 2. **Testable** — All logic can be unit tested without mocking
//! 3. **FFI-safe** — All types are UniFFI-compatible
//!
//! ## Usage Flow
//!
//! ```text
//! Swift: reads shell-cwd.json
//!    │
//!    ▼
//! Swift: queries tmux context (list-windows, list-clients)
//!    │
//!    ▼
//! Rust: resolve_activation(project_path, shell_state, tmux_context)
//!    │
//!    ▼
//! Swift: executes returned ActivationAction
//! ```

use crate::types::ParentApp;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

// ═══════════════════════════════════════════════════════════════════════════════
// FFI Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Shell state as read from `~/.capacitor/shell-cwd.json`.
///
/// This is the FFI-safe version of the shell state. Swift reads the JSON
/// and converts it to this type before passing to Rust.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ShellCwdStateFfi {
    pub version: u32,
    pub shells: HashMap<String, ShellEntryFfi>,
}

/// A single shell entry from the shell state.
#[derive(Debug, Clone, Serialize, Deserialize, uniffi::Record)]
pub struct ShellEntryFfi {
    pub cwd: String,
    pub tty: String,
    pub parent_app: ParentApp,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tmux_client_tty: Option<String>,
    pub updated_at: String,
}

/// Context about tmux state, queried by Swift before calling the resolver.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct TmuxContextFfi {
    /// Session name if one exists at the project path
    pub session_at_path: Option<String>,
    /// Whether any tmux client is currently attached
    pub has_attached_client: bool,
}

/// The resolved activation decision.
#[derive(Debug, Clone, uniffi::Record)]
pub struct ActivationDecision {
    /// Primary action to attempt
    pub primary: ActivationAction,
    /// Fallback action if primary fails
    pub fallback: Option<ActivationAction>,
    /// Debug context explaining why this decision was made
    pub reason: String,
}

/// A single action for Swift to execute.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum ActivationAction {
    /// Activate a terminal by querying for TTY ownership (AppleScript)
    ActivateByTty {
        tty: String,
        terminal_type: TerminalType,
    },

    /// Activate app by bringing its window to front
    ActivateApp { app_name: String },

    /// Focus kitty window by shell PID using `kitty @`
    ActivateKittyWindow { shell_pid: u32 },

    /// Activate IDE and run CLI to focus correct window
    ActivateIdeWindow {
        ide_type: IdeType,
        project_path: String,
    },

    /// Switch tmux session in attached client
    SwitchTmuxSession { session_name: String },

    /// Discover host terminal via TTY, then switch tmux session
    ActivateHostThenSwitchTmux {
        host_tty: String,
        session_name: String,
    },

    /// Launch new terminal with tmux attach
    LaunchTerminalWithTmux {
        session_name: String,
        project_path: String,
    },

    /// Launch new terminal at project path (no tmux)
    LaunchNewTerminal {
        project_path: String,
        project_name: String,
    },

    /// Activate first running terminal from priority list
    ActivatePriorityFallback,

    /// Do nothing
    Skip,
}

/// Terminal types that support TTY-based tab selection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum TerminalType {
    ITerm,
    TerminalApp,
    Ghostty,
    Alacritty,
    Kitty,
    Warp,
    Unknown,
}

impl From<ParentApp> for TerminalType {
    fn from(app: ParentApp) -> Self {
        match app {
            ParentApp::ITerm => Self::ITerm,
            ParentApp::Terminal => Self::TerminalApp,
            ParentApp::Ghostty => Self::Ghostty,
            ParentApp::Alacritty => Self::Alacritty,
            ParentApp::Kitty => Self::Kitty,
            ParentApp::Warp => Self::Warp,
            _ => Self::Unknown,
        }
    }
}

/// IDE types for window activation via CLI.
#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum IdeType {
    Cursor,
    VsCode,
    VsCodeInsiders,
    Zed,
}

impl TryFrom<ParentApp> for IdeType {
    type Error = ();

    fn try_from(app: ParentApp) -> Result<Self, Self::Error> {
        match app {
            ParentApp::Cursor => Ok(Self::Cursor),
            ParentApp::VSCode => Ok(Self::VsCode),
            ParentApp::VSCodeInsiders => Ok(Self::VsCodeInsiders),
            ParentApp::Zed => Ok(Self::Zed),
            _ => Err(()),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Resolution Logic
// ═══════════════════════════════════════════════════════════════════════════════

/// Resolves what activation action to take for a project.
///
/// This is the main entry point for terminal activation.
///
/// # Arguments
/// * `project_path` - The absolute path to the project
/// * `shell_state` - Current contents of shell-cwd.json (may be None if file missing)
/// * `tmux_context` - Tmux state queried by Swift
///
/// # Returns
/// An `ActivationDecision` with primary action and optional fallback.
pub fn resolve_activation(
    project_path: &str,
    shell_state: Option<&ShellCwdStateFfi>,
    tmux_context: &TmuxContextFfi,
) -> ActivationDecision {
    let normalized_path = normalize_path(project_path);

    // Priority 1: Find existing shell in shell-cwd.json
    if let Some(state) = shell_state {
        if let Some((pid, shell)) = find_shell_at_path(&state.shells, &normalized_path) {
            return resolve_for_existing_shell(pid, shell, tmux_context, &normalized_path);
        }
    }

    // Priority 2: Check for tmux session at path
    if let Some(session_name) = &tmux_context.session_at_path {
        return resolve_for_tmux_session(
            session_name,
            tmux_context.has_attached_client,
            &normalized_path,
        );
    }

    // Priority 3: Launch new terminal
    let project_name = normalized_path
        .rsplit('/')
        .next()
        .unwrap_or(&normalized_path)
        .to_string();

    ActivationDecision {
        primary: ActivationAction::LaunchNewTerminal {
            project_path: normalized_path,
            project_name,
        },
        fallback: None,
        reason: "No existing shell or tmux session found".to_string(),
    }
}

/// Find a shell entry at the given path.
///
/// Returns the most recently updated shell at the path. This ensures we
/// activate the terminal the user is *currently* working in, not a stale
/// entry from hours ago.
///
/// Note: We previously preferred tmux shells unconditionally, but this caused
/// issues when tmux shell data was stale (tmux_client_tty pointing to wrong
/// terminal). Now we prefer recency to ensure we activate the right window.
fn find_shell_at_path<'a>(
    shells: &'a HashMap<String, ShellEntryFfi>,
    project_path: &str,
) -> Option<(u32, &'a ShellEntryFfi)> {
    let mut best_shell: Option<(u32, &ShellEntryFfi)> = None;
    let mut best_timestamp: Option<&str> = None;

    for (pid_str, shell) in shells {
        let shell_path = normalize_path(&shell.cwd);
        if !paths_match(&shell_path, project_path) {
            continue;
        }

        let pid: u32 = match pid_str.parse() {
            Ok(p) => p,
            Err(_) => continue,
        };

        // Pick the most recently updated shell
        let is_newer =
            best_timestamp.is_none() || shell.updated_at.as_str() > best_timestamp.unwrap();
        if is_newer {
            best_shell = Some((pid, shell));
            best_timestamp = Some(&shell.updated_at);
        }
    }

    best_shell
}

/// Check if two paths refer to the same location.
fn paths_match(a: &str, b: &str) -> bool {
    // Exact match
    if a == b {
        return true;
    }

    // Check if one is a prefix of the other (subdir case)
    // This handles cases where shell is in /proj/src but project is /proj
    let (shorter, longer) = if a.len() < b.len() { (a, b) } else { (b, a) };
    if let Some(rest) = longer.strip_prefix(shorter) {
        return rest.is_empty() || rest.starts_with('/');
    }

    false
}

/// Resolve activation for an existing shell found in shell-cwd.json.
fn resolve_for_existing_shell(
    pid: u32,
    shell: &ShellEntryFfi,
    tmux_context: &TmuxContextFfi,
    project_path: &str,
) -> ActivationDecision {
    let parent_app = shell.parent_app;
    let has_tmux = shell.tmux_session.is_some();

    // IDE: Always use IDE window activation
    if parent_app.is_ide() {
        if let Ok(ide_type) = IdeType::try_from(parent_app) {
            let fallback = if has_tmux {
                shell
                    .tmux_session
                    .as_ref()
                    .map(|s| ActivationAction::SwitchTmuxSession {
                        session_name: s.clone(),
                    })
            } else {
                None
            };

            return ActivationDecision {
                primary: ActivationAction::ActivateIdeWindow {
                    ide_type,
                    project_path: shell.cwd.clone(),
                },
                fallback,
                reason: format!("Found shell (pid={}) in IDE {:?}", pid, parent_app),
            };
        }
    }

    // Tmux context: Check if client is actually attached
    // If no client is attached, the shell's tmux_client_tty is stale and we should
    // launch a new terminal to attach to the session instead of trying to activate.
    if has_tmux {
        let session_name = shell.tmux_session.as_ref().unwrap().clone();

        // KEY FIX: If no tmux client is attached, launch a new terminal to attach
        // instead of trying to activate a potentially stale TTY
        if !tmux_context.has_attached_client {
            return ActivationDecision {
                primary: ActivationAction::LaunchTerminalWithTmux {
                    session_name: session_name.clone(),
                    project_path: project_path.to_string(),
                },
                fallback: None,
                reason: format!(
                    "Found shell (pid={}) in tmux session '{}' but no client attached, launching terminal to attach",
                    pid, session_name
                ),
            };
        }

        // Client is attached, try to activate the host terminal
        let host_tty = shell
            .tmux_client_tty
            .clone()
            .unwrap_or_else(|| shell.tty.clone());

        return ActivationDecision {
            primary: ActivationAction::ActivateHostThenSwitchTmux {
                host_tty,
                session_name,
            },
            fallback: Some(ActivationAction::ActivatePriorityFallback),
            reason: format!(
                "Found shell (pid={}) in tmux session '{}'",
                pid,
                shell.tmux_session.as_ref().unwrap()
            ),
        };
    }

    // Kitty: Use remote control for precise window focus
    if parent_app == ParentApp::Kitty {
        return ActivationDecision {
            primary: ActivationAction::ActivateKittyWindow { shell_pid: pid },
            fallback: Some(ActivationAction::ActivateApp {
                app_name: "kitty".to_string(),
            }),
            reason: format!("Found shell (pid={}) in kitty", pid),
        };
    }

    // iTerm/Terminal.app: Use TTY-based tab selection
    if parent_app == ParentApp::ITerm || parent_app == ParentApp::Terminal {
        return ActivationDecision {
            primary: ActivationAction::ActivateByTty {
                tty: shell.tty.clone(),
                terminal_type: TerminalType::from(parent_app),
            },
            fallback: None,
            reason: format!(
                "Found shell (pid={}) in {:?}, using TTY lookup",
                pid, parent_app
            ),
        };
    }

    // Ghostty/Alacritty/Warp: No tab selection, just activate app
    if parent_app.is_terminal() {
        let app_name = match parent_app {
            ParentApp::Ghostty => "Ghostty",
            ParentApp::Alacritty => "Alacritty",
            ParentApp::Warp => "Warp",
            _ => "Terminal",
        };

        return ActivationDecision {
            primary: ActivationAction::ActivateApp {
                app_name: app_name.to_string(),
            },
            fallback: None,
            reason: format!(
                "Found shell (pid={}) in {}, activating app (no tab selection)",
                pid, app_name
            ),
        };
    }

    // Unknown parent: Try TTY discovery with fallback
    ActivationDecision {
        primary: ActivationAction::ActivateByTty {
            tty: shell.tty.clone(),
            terminal_type: TerminalType::Unknown,
        },
        fallback: Some(ActivationAction::ActivatePriorityFallback),
        reason: format!(
            "Found shell (pid={}) with unknown parent, trying TTY discovery",
            pid
        ),
    }
}

/// Resolve activation when a tmux session exists but no shell in state.
fn resolve_for_tmux_session(
    session_name: &str,
    has_attached_client: bool,
    project_path: &str,
) -> ActivationDecision {
    if has_attached_client {
        // Client is attached: switch session, then activate terminal
        ActivationDecision {
            primary: ActivationAction::SwitchTmuxSession {
                session_name: session_name.to_string(),
            },
            fallback: Some(ActivationAction::ActivatePriorityFallback),
            reason: format!(
                "Tmux session '{}' exists with attached client",
                session_name
            ),
        }
    } else {
        // No client attached: launch new terminal that attaches to session
        // THIS IS THE BUG FIX: Previously this case wasn't handled correctly
        ActivationDecision {
            primary: ActivationAction::LaunchTerminalWithTmux {
                session_name: session_name.to_string(),
                project_path: project_path.to_string(),
            },
            fallback: None,
            reason: format!(
                "Tmux session '{}' exists but no client attached, launching terminal to attach",
                session_name
            ),
        }
    }
}

/// Normalize a path by stripping trailing slashes.
fn normalize_path(path: &str) -> String {
    if path == "/" {
        path.to_string()
    } else {
        path.trim_end_matches('/').to_string()
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Tests
// ═══════════════════════════════════════════════════════════════════════════════

#[cfg(test)]
mod tests {
    use super::*;

    // ─────────────────────────────────────────────────────────────────────────────
    // Test Helpers
    // ─────────────────────────────────────────────────────────────────────────────

    fn make_shell_entry(
        cwd: &str,
        tty: &str,
        parent_app: ParentApp,
        tmux_session: Option<&str>,
    ) -> ShellEntryFfi {
        make_shell_entry_with_time(cwd, tty, parent_app, tmux_session, "2026-01-27T10:00:00Z")
    }

    fn make_shell_entry_with_time(
        cwd: &str,
        tty: &str,
        parent_app: ParentApp,
        tmux_session: Option<&str>,
        updated_at: &str,
    ) -> ShellEntryFfi {
        ShellEntryFfi {
            cwd: cwd.to_string(),
            tty: tty.to_string(),
            parent_app,
            tmux_session: tmux_session.map(|s| s.to_string()),
            tmux_client_tty: tmux_session.map(|_| "/dev/ttys000".to_string()),
            updated_at: updated_at.to_string(),
        }
    }

    fn make_shell_state(shells: Vec<(&str, ShellEntryFfi)>) -> ShellCwdStateFfi {
        ShellCwdStateFfi {
            version: 1,
            shells: shells
                .into_iter()
                .map(|(pid, entry)| (pid.to_string(), entry))
                .collect(),
        }
    }

    fn tmux_context_none() -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: None,
            has_attached_client: false,
        }
    }

    fn tmux_context_attached(session: &str) -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: Some(session.to_string()),
            has_attached_client: true,
        }
    }

    fn tmux_context_detached(session: &str) -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: Some(session.to_string()),
            has_attached_client: false,
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: No existing shell, no tmux session
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_no_shell_no_tmux_launches_new_terminal() {
        let decision = resolve_activation("/Users/pete/Code/myproject", None, &tmux_context_none());

        assert!(matches!(
            decision.primary,
            ActivationAction::LaunchNewTerminal { .. }
        ));
        assert!(decision.fallback.is_none());

        if let ActivationAction::LaunchNewTerminal {
            project_path,
            project_name,
        } = decision.primary
        {
            assert_eq!(project_path, "/Users/pete/Code/myproject");
            assert_eq!(project_name, "myproject");
        }
    }

    #[test]
    fn test_empty_shell_state_launches_new_terminal() {
        let state = make_shell_state(vec![]);
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::LaunchNewTerminal { .. }
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Tmux session exists (no shell in state)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_tmux_session_with_attached_client_switches_session() {
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            None,
            &tmux_context_attached("myproject"),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::SwitchTmuxSession { .. }
        ));
        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::ActivatePriorityFallback)
        ));

        if let ActivationAction::SwitchTmuxSession { session_name } = decision.primary {
            assert_eq!(session_name, "myproject");
        }
    }

    #[test]
    fn test_tmux_session_without_client_launches_terminal_with_tmux() {
        // THIS IS THE BUG FIX TEST
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            None,
            &tmux_context_detached("myproject"),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux { .. }
            ),
            "Expected LaunchTerminalWithTmux when tmux session exists but no client attached"
        );

        if let ActivationAction::LaunchTerminalWithTmux {
            session_name,
            project_path,
        } = decision.primary
        {
            assert_eq!(session_name, "myproject");
            assert_eq!(project_path, "/Users/pete/Code/myproject");
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Shell exists in shell-cwd.json (Native Terminal)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_iterm_shell_uses_tty_activation() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::ITerm,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateByTty {
                terminal_type: TerminalType::ITerm,
                ..
            }
        ));
    }

    #[test]
    fn test_terminal_app_shell_uses_tty_activation() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Terminal,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateByTty {
                terminal_type: TerminalType::TerminalApp,
                ..
            }
        ));
    }

    #[test]
    fn test_ghostty_shell_activates_app() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Ghostty,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateApp { .. }
        ));

        if let ActivationAction::ActivateApp { app_name } = decision.primary {
            assert_eq!(app_name, "Ghostty");
        }
    }

    #[test]
    fn test_kitty_shell_uses_remote_control() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Kitty,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateKittyWindow { shell_pid: 12345 }
        ));

        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::ActivateApp { .. })
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Shell exists in shell-cwd.json (IDE)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_cursor_shell_activates_ide_window() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Cursor,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateIdeWindow {
                ide_type: IdeType::Cursor,
                ..
            }
        ));
    }

    #[test]
    fn test_vscode_shell_activates_ide_window() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::VSCode,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateIdeWindow {
                ide_type: IdeType::VsCode,
                ..
            }
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Shell exists in shell-cwd.json (with tmux)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_tmux_shell_with_client_activates_host_then_switches() {
        // When a tmux shell exists AND a client is attached,
        // we activate the host terminal and switch sessions
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/pts/0",
                ParentApp::Tmux,
                Some("myproject"),
            ),
        )]);

        // Client IS attached
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_attached("myproject"),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateHostThenSwitchTmux { .. }
        ));

        if let ActivationAction::ActivateHostThenSwitchTmux {
            host_tty,
            session_name,
        } = decision.primary
        {
            assert_eq!(host_tty, "/dev/ttys000"); // tmux_client_tty
            assert_eq!(session_name, "myproject");
        }
    }

    #[test]
    fn test_tmux_shell_without_client_launches_terminal() {
        // When a tmux shell exists BUT no client is attached (terminal window closed),
        // we should launch a new terminal to attach to the session
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/pts/0",
                ParentApp::Tmux,
                Some("myproject"),
            ),
        )]);

        // No client attached (the bug scenario!)
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux { .. }
            ),
            "Expected LaunchTerminalWithTmux when shell exists but no client attached, got {:?}",
            decision.primary
        );

        if let ActivationAction::LaunchTerminalWithTmux {
            session_name,
            project_path,
        } = decision.primary
        {
            assert_eq!(session_name, "myproject");
            assert_eq!(project_path, "/Users/pete/Code/myproject");
        }
    }

    #[test]
    fn test_ide_with_tmux_has_switch_fallback() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/pts/0",
                ParentApp::Cursor,
                Some("myproject"),
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateIdeWindow {
                ide_type: IdeType::Cursor,
                ..
            }
        ));

        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::SwitchTmuxSession { .. })
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Unknown parent app
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_unknown_parent_uses_tty_with_fallback() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Unknown,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateByTty {
                terminal_type: TerminalType::Unknown,
                ..
            }
        ));

        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::ActivatePriorityFallback)
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Multiple shells at same path
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_prefers_most_recent_shell() {
        // Old tmux shell (stale data)
        let old_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("myproject"),
            "2026-01-27T07:00:00Z", // 3 hours ago
        );

        // Recent direct shell (current)
        let recent_direct_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys003",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z", // now
        );

        let state = make_shell_state(vec![
            ("12345", recent_direct_shell),
            ("67890", old_tmux_shell),
        ]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        // Should pick the MORE RECENT shell (Ghostty), not the stale tmux shell
        assert!(
            matches!(decision.primary, ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"),
            "Expected ActivateApp(Ghostty), got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_prefers_recent_tmux_over_old_direct_with_client() {
        // Old direct shell
        let old_direct_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys003",
            ParentApp::Ghostty,
            None,
            "2026-01-27T07:00:00Z", // 3 hours ago
        );

        // Recent tmux shell
        let recent_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("myproject"),
            "2026-01-27T10:00:00Z", // now
        );

        let state = make_shell_state(vec![
            ("12345", old_direct_shell),
            ("67890", recent_tmux_shell),
        ]);

        // Client IS attached
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_attached("myproject"),
        );

        // Should pick the MORE RECENT shell (tmux) and activate via host
        assert!(
            matches!(
                decision.primary,
                ActivationAction::ActivateHostThenSwitchTmux { .. }
            ),
            "Expected ActivateHostThenSwitchTmux, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_prefers_recent_tmux_over_old_direct_without_client() {
        // Old direct shell
        let old_direct_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys003",
            ParentApp::Ghostty,
            None,
            "2026-01-27T07:00:00Z", // 3 hours ago
        );

        // Recent tmux shell
        let recent_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("myproject"),
            "2026-01-27T10:00:00Z", // now
        );

        let state = make_shell_state(vec![
            ("12345", old_direct_shell),
            ("67890", recent_tmux_shell),
        ]);

        // No client attached - should launch new terminal
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        // Should pick the MORE RECENT shell (tmux) but launch new terminal since no client
        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux { .. }
            ),
            "Expected LaunchTerminalWithTmux when tmux shell is recent but no client, got {:?}",
            decision.primary
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Path normalization
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_trailing_slash_normalized() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Ghostty,
                None,
            ),
        )]);

        // Query with trailing slash should still match
        let decision = resolve_activation(
            "/Users/pete/Code/myproject/",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateApp { .. }
        ));
    }

    #[test]
    fn test_shell_in_subdir_matches_parent() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject/src",
                "/dev/ttys003",
                ParentApp::Ghostty,
                None,
            ),
        )]);

        // Shell is in /myproject/src, but we're activating /myproject
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateApp { .. }
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Shell state priority over tmux context
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_shell_state_takes_priority_over_tmux_context() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys003",
                ParentApp::Ghostty,
                None,
            ),
        )]);

        // Even if tmux context says there's a session, shell state wins
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_attached("myproject"),
        );

        // Should use the shell state, not the tmux context
        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateApp { app_name } if app_name == "Ghostty"
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Path matching tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_paths_match_exact() {
        assert!(paths_match(
            "/Users/pete/Code/project",
            "/Users/pete/Code/project"
        ));
    }

    #[test]
    fn test_paths_match_subdir() {
        assert!(paths_match(
            "/Users/pete/Code/project/src",
            "/Users/pete/Code/project"
        ));
        assert!(paths_match(
            "/Users/pete/Code/project",
            "/Users/pete/Code/project/src"
        ));
    }

    #[test]
    fn test_paths_no_match_different() {
        assert!(!paths_match(
            "/Users/pete/Code/project",
            "/Users/pete/Code/other"
        ));
    }

    #[test]
    fn test_paths_no_match_partial_name() {
        // /project should not match /projectfoo
        assert!(!paths_match(
            "/Users/pete/Code/project",
            "/Users/pete/Code/projectfoo"
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Normalize path tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_normalize_path_strips_trailing_slash() {
        assert_eq!(normalize_path("/foo/bar/"), "/foo/bar");
        assert_eq!(normalize_path("/foo/bar"), "/foo/bar");
    }

    #[test]
    fn test_normalize_path_preserves_root() {
        assert_eq!(normalize_path("/"), "/");
    }
}

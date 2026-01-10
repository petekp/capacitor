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
//! Swift: fetches runtime shell state snapshot
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

mod policy;
mod trace;

use crate::domain::normalize_path_for_matching;
use crate::runtime_types::ParentApp;
use policy::{select_best_shell, SelectionPolicy};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use trace::DecisionTraceFfi;

// ═══════════════════════════════════════════════════════════════════════════════
// FFI Types
// ═══════════════════════════════════════════════════════════════════════════════

/// Shell state as returned by the runtime snapshot.
///
/// This is the FFI-safe version of the shell state. Swift fetches the runtime
/// snapshot and converts it to this type before passing to Rust.
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
    /// Whether the shell process is still running (verified via kill(pid, 0))
    #[serde(default)]
    pub is_live: bool,
}

/// Context about tmux state, queried by Swift before calling the resolver.
#[derive(Debug, Clone, Default, uniffi::Record)]
pub struct TmuxContextFfi {
    /// Session name if one exists at the project path
    pub session_at_path: Option<String>,
    /// Whether any tmux client is currently attached
    pub has_attached_client: bool,
    /// User's home directory (e.g., "/Users/pete") - excluded from parent matching
    pub home_dir: String,
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
    /// Optional decision trace for debugging selection logic
    pub trace: Option<DecisionTraceFfi>,
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

    /// Ensure tmux session exists (create if needed), then switch
    EnsureTmuxSession {
        session_name: String,
        project_path: String,
    },

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
/// * `shell_state` - Current runtime shell snapshot (may be None if unavailable)
/// * `tmux_context` - Tmux state queried by Swift
///
/// # Returns
/// An `ActivationDecision` with primary action and optional fallback.
pub fn resolve_activation(
    project_path: &str,
    shell_state: Option<&ShellCwdStateFfi>,
    tmux_context: &TmuxContextFfi,
) -> ActivationDecision {
    resolve_activation_internal(project_path, shell_state, tmux_context, false)
}

/// Resolves what activation action to take for a project, optionally returning a trace.
pub fn resolve_activation_with_trace(
    project_path: &str,
    shell_state: Option<&ShellCwdStateFfi>,
    tmux_context: &TmuxContextFfi,
    include_trace: bool,
) -> ActivationDecision {
    resolve_activation_internal(project_path, shell_state, tmux_context, include_trace)
}

fn resolve_activation_internal(
    project_path: &str,
    shell_state: Option<&ShellCwdStateFfi>,
    tmux_context: &TmuxContextFfi,
    include_trace: bool,
) -> ActivationDecision {
    let action_path = normalize_path_for_actions(project_path);
    let mut trace: Option<DecisionTraceFfi> = None;

    // Priority 1: Find existing shell in runtime snapshot.
    if let Some(state) = shell_state {
        let policy = SelectionPolicy {
            prefer_tmux: tmux_context.has_attached_client,
        };
        let selection = select_best_shell(
            &state.shells,
            project_path,
            &tmux_context.home_dir,
            &policy,
            include_trace,
        );

        let best_live = selection
            .best
            .as_ref()
            .filter(|candidate| candidate.is_live);

        if include_trace {
            trace = Some(DecisionTraceFfi::from_shell_candidates(
                &policy,
                &selection.candidates,
                best_live.map(|candidate| candidate.pid),
            ));
        }

        if let Some(best) = best_live {
            if let Some(session_name) = &tmux_context.session_at_path {
                if should_prefer_tmux_session(best.shell, &action_path, session_name) {
                    let mut decision = resolve_for_tmux_session(
                        session_name,
                        tmux_context.has_attached_client,
                        &action_path,
                    );
                    decision.reason = format!(
                        "Tmux session '{}' matches project; preferring tmux over non-tmux shell (pid={})",
                        session_name, best.pid
                    );
                    decision.trace = trace;
                    return decision;
                }
            }

            let mut decision =
                resolve_for_existing_shell(best.pid, best.shell, tmux_context, &action_path);
            decision.trace = trace;
            return decision;
        }
    }

    // Priority 2: Check for tmux session at path
    if let Some(session_name) = &tmux_context.session_at_path {
        let mut decision =
            resolve_for_tmux_session(session_name, tmux_context.has_attached_client, &action_path);
        decision.trace = trace;
        return decision;
    }

    // Priority 3: If tmux client is attached, ensure a session for this project.
    if tmux_context.has_attached_client {
        let project_name = action_path
            .rsplit('/')
            .next()
            .unwrap_or(&action_path)
            .to_string();

        let mut decision = ActivationDecision {
            primary: ActivationAction::EnsureTmuxSession {
                session_name: project_name,
                project_path: action_path,
            },
            fallback: Some(ActivationAction::ActivatePriorityFallback),
            reason:
                "No existing shell or tmux session found; tmux client attached, ensuring session"
                    .to_string(),
            trace: None,
        };
        decision.trace = trace;
        return decision;
    }

    // Priority 4: Prefer activating an existing terminal app, then fall back to launch.
    let project_name = action_path
        .rsplit('/')
        .next()
        .unwrap_or(&action_path)
        .to_string();

    let mut decision = ActivationDecision {
        primary: ActivationAction::ActivatePriorityFallback,
        fallback: Some(ActivationAction::LaunchNewTerminal {
            project_path: action_path,
            project_name,
        }),
        reason:
            "No existing shell or tmux session found; activating existing terminal if available"
                .to_string(),
        trace: None,
    };
    decision.trace = trace;
    decision
}

/// Check if two paths refer to the same location or are parent/child.
///
/// Returns true if:
/// - The paths are identical
/// - One path is a subdirectory of the other
///
/// This allows activating a shell in `/project/src` when clicking `/project`.
#[uniffi::export]
pub fn paths_match(a: &str, b: &str) -> bool {
    let normalized_a = normalize_path_for_matching(a);
    let normalized_b = normalize_path_for_matching(b);

    if normalized_a == normalized_b {
        return true;
    }

    // Check if one is a subdirectory of the other (e.g., /proj matches /proj/src)
    let (shorter, longer) = if normalized_a.len() < normalized_b.len() {
        (normalized_a.as_str(), normalized_b.as_str())
    } else {
        (normalized_b.as_str(), normalized_a.as_str())
    };
    longer
        .strip_prefix(shorter)
        .is_some_and(|rest| rest.starts_with('/'))
}

/// Formats a decision trace for logging.
#[uniffi::export]
pub fn format_activation_trace(trace: DecisionTraceFfi) -> String {
    trace::format_decision_trace(&trace)
}

/// Check if two paths match, excluding HOME as a parent.
///
/// HOME is a parent of nearly everything, making it too broad for useful matching.
/// A shell at `/Users/pete` should NOT match `/Users/pete/Code/myproject` just
/// because HOME is technically a parent directory.
///
/// Used in tests to validate HOME exclusion behavior.
#[cfg(test)]
fn paths_match_excluding_home(shell_path: &str, project_path: &str, home_dir: &str) -> bool {
    let shell_path = normalize_path_for_matching(shell_path);
    let project_path = normalize_path_for_matching(project_path);
    let home_dir = normalize_path_for_matching(home_dir);
    policy::match_type_excluding_home(&shell_path, &project_path, &home_dir).is_some()
}

/// Resolve activation for an existing shell found in the runtime snapshot.
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
            let fallback = if tmux_context.has_attached_client {
                let session_name = shell.tmux_session.clone().unwrap_or_else(|| {
                    project_path
                        .rsplit('/')
                        .next()
                        .unwrap_or(project_path)
                        .to_string()
                });
                Some(ActivationAction::EnsureTmuxSession {
                    session_name,
                    project_path: project_path.to_string(),
                })
            } else if has_tmux {
                shell
                    .tmux_session
                    .as_ref()
                    .map(|s| ActivationAction::LaunchTerminalWithTmux {
                        session_name: s.clone(),
                        project_path: project_path.to_string(),
                    })
            } else {
                let project_name = project_path
                    .rsplit('/')
                    .next()
                    .unwrap_or(project_path)
                    .to_string();
                Some(ActivationAction::LaunchNewTerminal {
                    project_path: project_path.to_string(),
                    project_name,
                })
            };

            return ActivationDecision {
                primary: ActivationAction::ActivateIdeWindow {
                    ide_type,
                    project_path: shell.cwd.clone(),
                },
                fallback,
                reason: format!("Found shell (pid={}) in IDE {:?}", pid, parent_app),
                trace: None,
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
                trace: None,
            };
        }

        // Client is attached, try to activate the host terminal
        let host_tty = shell
            .tmux_client_tty
            .clone()
            .unwrap_or_else(|| shell.tty.clone());

        let session_name_for_action = session_name.clone();

        return ActivationDecision {
            primary: ActivationAction::ActivateHostThenSwitchTmux {
                host_tty,
                session_name: session_name_for_action,
            },
            fallback: Some(ActivationAction::LaunchTerminalWithTmux {
                session_name: session_name.clone(),
                project_path: project_path.to_string(),
            }),
            reason: format!(
                "Found shell (pid={}) in tmux session '{}'",
                pid,
                shell.tmux_session.as_ref().unwrap()
            ),
            trace: None,
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
            trace: None,
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
            trace: None,
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

        let fallback = if tmux_context.has_attached_client {
            let session_name = tmux_context.session_at_path.clone().unwrap_or_else(|| {
                project_path
                    .rsplit('/')
                    .next()
                    .unwrap_or(project_path)
                    .to_string()
            });

            Some(ActivationAction::EnsureTmuxSession {
                session_name,
                project_path: project_path.to_string(),
            })
        } else if let Some(session_name) = &tmux_context.session_at_path {
            Some(ActivationAction::LaunchTerminalWithTmux {
                session_name: session_name.clone(),
                project_path: project_path.to_string(),
            })
        } else {
            let project_name = project_path
                .rsplit('/')
                .next()
                .unwrap_or(project_path)
                .to_string();

            Some(ActivationAction::LaunchNewTerminal {
                project_path: project_path.to_string(),
                project_name,
            })
        };

        return ActivationDecision {
            primary: ActivationAction::ActivateApp {
                app_name: app_name.to_string(),
            },
            fallback,
            reason: format!(
                "Found shell (pid={}) in {}, activating app (no tab selection)",
                pid, app_name
            ),
            trace: None,
        };
    }

    // Unknown parent with attached tmux client: prefer tmux session.
    if tmux_context.has_attached_client {
        let session_name = tmux_context.session_at_path.clone().unwrap_or_else(|| {
            project_path
                .rsplit('/')
                .next()
                .unwrap_or(project_path)
                .to_string()
        });

        return ActivationDecision {
            primary: ActivationAction::EnsureTmuxSession {
                session_name: session_name.clone(),
                project_path: project_path.to_string(),
            },
            fallback: Some(ActivationAction::ActivateByTty {
                tty: shell.tty.clone(),
                terminal_type: TerminalType::Unknown,
            }),
            reason: format!(
                "Found shell (pid={}) with unknown parent and attached tmux client, ensuring session '{}'",
                pid, session_name
            ),
            trace: None,
        };
    }

    // Unknown parent: Try TTY discovery with a launch fallback.
    let fallback = if tmux_context.has_attached_client {
        let session_name = tmux_context.session_at_path.clone().unwrap_or_else(|| {
            project_path
                .rsplit('/')
                .next()
                .unwrap_or(project_path)
                .to_string()
        });
        Some(ActivationAction::EnsureTmuxSession {
            session_name,
            project_path: project_path.to_string(),
        })
    } else if let Some(session_name) = &tmux_context.session_at_path {
        Some(ActivationAction::LaunchTerminalWithTmux {
            session_name: session_name.clone(),
            project_path: project_path.to_string(),
        })
    } else {
        let project_name = project_path
            .rsplit('/')
            .next()
            .unwrap_or(project_path)
            .to_string();
        Some(ActivationAction::LaunchNewTerminal {
            project_path: project_path.to_string(),
            project_name,
        })
    };

    ActivationDecision {
        primary: ActivationAction::ActivateByTty {
            tty: shell.tty.clone(),
            terminal_type: TerminalType::Unknown,
        },
        fallback,
        reason: format!(
            "Found shell (pid={}) with unknown parent, trying TTY discovery",
            pid
        ),
        trace: None,
    }
}

fn should_prefer_tmux_session(
    shell: &ShellEntryFfi,
    project_path: &str,
    session_name: &str,
) -> bool {
    if shell.tmux_session.is_some() || shell.parent_app.is_ide() {
        return false;
    }

    let project_name = project_path.rsplit('/').next().unwrap_or(project_path);

    session_name == project_name
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
            trace: None,
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
            trace: None,
        }
    }
}

/// Normalize a path by stripping trailing slashes.
fn normalize_path_for_actions(path: &str) -> String {
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
        make_shell_entry_full(
            cwd,
            tty,
            parent_app,
            tmux_session,
            "2026-01-27T10:00:00Z",
            true,
        )
    }

    fn make_shell_entry_with_time(
        cwd: &str,
        tty: &str,
        parent_app: ParentApp,
        tmux_session: Option<&str>,
        updated_at: &str,
    ) -> ShellEntryFfi {
        make_shell_entry_full(cwd, tty, parent_app, tmux_session, updated_at, true)
    }

    fn make_shell_entry_full(
        cwd: &str,
        tty: &str,
        parent_app: ParentApp,
        tmux_session: Option<&str>,
        updated_at: &str,
        is_live: bool,
    ) -> ShellEntryFfi {
        ShellEntryFfi {
            cwd: cwd.to_string(),
            tty: tty.to_string(),
            parent_app,
            tmux_session: tmux_session.map(|s| s.to_string()),
            tmux_client_tty: tmux_session.map(|_| "/dev/ttys000".to_string()),
            updated_at: updated_at.to_string(),
            is_live,
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

    const TEST_HOME_DIR: &str = "/Users/pete";

    fn tmux_context_none() -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: None,
            has_attached_client: false,
            home_dir: TEST_HOME_DIR.to_string(),
        }
    }

    fn tmux_context_attached(session: &str) -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: Some(session.to_string()),
            has_attached_client: true,
            home_dir: TEST_HOME_DIR.to_string(),
        }
    }

    fn tmux_context_attached_no_session() -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: None,
            has_attached_client: true,
            home_dir: TEST_HOME_DIR.to_string(),
        }
    }

    fn tmux_context_detached(session: &str) -> TmuxContextFfi {
        TmuxContextFfi {
            session_at_path: Some(session.to_string()),
            has_attached_client: false,
            home_dir: TEST_HOME_DIR.to_string(),
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: No existing shell, no tmux session
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_no_shell_no_tmux_prefers_activate_existing_terminal() {
        let decision = resolve_activation("/Users/pete/Code/myproject", None, &tmux_context_none());

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivatePriorityFallback
        ));
        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::LaunchNewTerminal { .. })
        ));

        if let Some(ActivationAction::LaunchNewTerminal {
            project_path,
            project_name,
        }) = decision.fallback
        {
            assert_eq!(project_path, "/Users/pete/Code/myproject");
            assert_eq!(project_name, "myproject");
        }
    }

    #[test]
    fn test_empty_shell_state_prefers_activate_existing_terminal() {
        let state = make_shell_state(vec![]);
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivatePriorityFallback
        ));
        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::LaunchNewTerminal { .. })
        ));
    }

    #[test]
    fn test_no_shell_with_attached_tmux_ensures_session() {
        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            None,
            &tmux_context_attached_no_session(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::EnsureTmuxSession { .. }
        ));

        if let ActivationAction::EnsureTmuxSession {
            session_name,
            project_path,
        } = decision.primary
        {
            assert_eq!(session_name, "myproject");
            assert_eq!(project_path, "/Users/pete/Code/myproject");
        }
    }

    #[test]
    fn test_known_terminal_beats_newer_unknown_shell() {
        let state = make_shell_state(vec![
            (
                "100",
                make_shell_entry_with_time(
                    "/Users/pete/Code/myproject",
                    "/dev/ttys001",
                    ParentApp::Unknown,
                    None,
                    "2026-01-27T10:10:00Z",
                ),
            ),
            (
                "200",
                make_shell_entry_with_time(
                    "/Users/pete/Code/myproject",
                    "/dev/ttys002",
                    ParentApp::Ghostty,
                    None,
                    "2026-01-27T10:09:00Z",
                ),
            ),
        ]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"
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

    #[test]
    fn test_dead_shell_does_not_block_tmux_session_launch() {
        let dead_shell = make_shell_entry_full(
            "/Users/pete/Code/personality",
            "/dev/ttys003",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z",
            false,
        );

        let state = make_shell_state(vec![("12345", dead_shell)]);

        let decision = resolve_activation(
            "/Users/pete/Code/personality",
            Some(&state),
            &tmux_context_detached("personality"),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux {
                    ref session_name,
                    ref project_path
                } if session_name == "personality" && project_path == "/Users/pete/Code/personality"
            ),
            "Expected LaunchTerminalWithTmux when only dead shell exists, got {:?}",
            decision.primary
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Shell exists in runtime shell snapshot (Native Terminal)
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

        assert!(
            matches!(
                decision.fallback,
                Some(ActivationAction::LaunchNewTerminal {
                    ref project_path,
                    ref project_name,
                }) if project_path == "/Users/pete/Code/myproject" && project_name == "myproject"
            ),
            "Expected LaunchNewTerminal fallback for Ghostty app activation, got {:?}",
            decision.fallback
        );
    }

    #[test]
    fn test_ghostty_shell_prefers_tmux_launch_when_session_exists() {
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
            &tmux_context_detached("myproject"),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux {
                    ref session_name,
                    ref project_path
                } if session_name == "myproject" && project_path == "/Users/pete/Code/myproject"
            ),
            "Expected LaunchTerminalWithTmux primary when tmux session exists, got {:?}",
            decision.primary
        );
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
    // Scenario: Shell exists in runtime shell snapshot (IDE)
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

        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::LaunchNewTerminal {
                project_path,
                project_name,
            }) if project_path == "/Users/pete/Code/myproject" && project_name == "myproject"
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

        assert!(matches!(
            decision.fallback,
            Some(ActivationAction::LaunchNewTerminal {
                project_path,
                project_name,
            }) if project_path == "/Users/pete/Code/myproject" && project_name == "myproject"
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Shell exists in runtime shell snapshot (with tmux)
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

        assert!(
            matches!(
                decision.fallback,
                Some(ActivationAction::LaunchTerminalWithTmux {
                    ref session_name,
                    ref project_path,
                }) if session_name == "myproject" && project_path == "/Users/pete/Code/myproject"
            ),
            "Expected LaunchTerminalWithTmux fallback when tmux client attached, got {:?}",
            decision.fallback
        );
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
    fn test_ide_with_tmux_attached_has_ensure_fallback() {
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
            &tmux_context_attached("myproject"),
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
            Some(ActivationAction::EnsureTmuxSession { .. })
        ));
    }

    #[test]
    fn test_ide_without_tmux_with_attached_client_ensures_session() {
        let state = make_shell_state(vec![(
            "12345",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/pts/0",
                ParentApp::Cursor,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_attached_no_session(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateIdeWindow {
                ide_type: IdeType::Cursor,
                ..
            }
        ));

        assert!(
            matches!(
                decision.fallback,
                Some(ActivationAction::EnsureTmuxSession { ref session_name, .. })
                    if session_name == "myproject"
            ),
            "Expected EnsureTmuxSession fallback when tmux client attached, got {:?}",
            decision.fallback
        );
    }

    #[test]
    fn test_ide_with_tmux_no_client_fallbacks_to_launch_with_tmux() {
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
            &tmux_context_detached("myproject"),
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
            Some(ActivationAction::LaunchTerminalWithTmux { .. })
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
            Some(ActivationAction::LaunchNewTerminal {
                project_path,
                project_name,
            }) if project_path == "/Users/pete/Code/myproject" && project_name == "myproject"
        ));
    }

    #[test]
    fn test_unknown_parent_with_tmux_session_launches_terminal_with_tmux() {
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
            &tmux_context_detached("myproject"),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux {
                    ref session_name,
                    ref project_path,
                } if session_name == "myproject" && project_path == "/Users/pete/Code/myproject"
            ),
            "Expected LaunchTerminalWithTmux primary when tmux session exists, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_unknown_parent_with_attached_tmux_client_ensures_session() {
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
            &tmux_context_attached_no_session(),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::EnsureTmuxSession {
                    ref session_name,
                    ref project_path,
                } if session_name == "myproject" && project_path == "/Users/pete/Code/myproject"
            ),
            "Expected EnsureTmuxSession primary when tmux client attached, got {:?}",
            decision.primary
        );
        assert!(
            matches!(
                decision.fallback,
                Some(ActivationAction::ActivateByTty {
                    terminal_type: TerminalType::Unknown,
                    ..
                })
            ),
            "Expected ActivateByTty fallback when tmux ensure fails, got {:?}",
            decision.fallback
        );
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

    #[test]
    fn test_exact_match_beats_parent_even_if_older() {
        let parent_shell = make_shell_entry_with_time(
            "/Users/pete/Code/monorepo",
            "/dev/ttys001",
            ParentApp::Ghostty,
            None,
            "2026-01-27T11:00:00Z", // Newer
        );

        let exact_shell = make_shell_entry_with_time(
            "/Users/pete/Code/monorepo/app",
            "/dev/ttys002",
            ParentApp::Terminal,
            None,
            "2026-01-27T10:00:00Z", // Older
        );

        let state = make_shell_state(vec![("11111", parent_shell), ("22222", exact_shell)]);

        let decision = resolve_activation(
            "/Users/pete/Code/monorepo/app",
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
    fn test_child_match_beats_parent_even_if_older() {
        let parent_shell = make_shell_entry_with_time(
            "/Users/pete/Code",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            "2026-01-27T11:00:00Z", // Newer
        );

        let child_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject/src",
            "/dev/ttys002",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z", // Older
        );

        let state = make_shell_state(vec![("11111", parent_shell), ("22222", child_shell)]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Tmux takes priority over non-tmux shells when attached
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_non_tmux_shell_prefers_matching_tmux_session_when_client_attached() {
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
            &tmux_context_attached("myproject"),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::SwitchTmuxSession { ref session_name } if session_name == "myproject"
            ),
            "Expected SwitchTmuxSession(myproject), got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_non_tmux_shell_with_attached_tmux_prefers_terminal() {
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
            &tmux_context_attached_no_session(),
        );

        assert!(matches!(
            decision.primary,
            ActivationAction::ActivateByTty {
                terminal_type: TerminalType::TerminalApp,
                ..
            }
        ));
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Path matching tests
    // ─────────────────────────────────────────────────────────────────────────────

    // ─────────────────────────────────────────────────────────────────────────────
    // Scenario: Multiple shells with mixed tmux/non-tmux (the bug scenario!)
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_prefers_tmux_shell_when_client_attached_even_if_older() {
        // THE BUG SCENARIO: User has multiple shells at same path
        // - One tmux shell (older timestamp)
        // - Two non-tmux shells (newer timestamps)
        // When tmux client IS attached, we should pick the tmux shell
        // to enable proper session switching

        let old_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/capacitor",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("capacitor"),
            "2026-01-27T08:00:00Z", // Older
        );

        let recent_nontmux_shell1 = make_shell_entry_with_time(
            "/Users/pete/Code/capacitor",
            "/dev/ttys001",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z", // Newer
        );

        let recent_nontmux_shell2 = make_shell_entry_with_time(
            "/Users/pete/Code/capacitor",
            "/dev/ttys002",
            ParentApp::Unknown, // Unknown parent, no tmux
            None,
            "2026-01-27T09:30:00Z", // Also newer
        );

        let state = make_shell_state(vec![
            ("11111", old_tmux_shell),
            ("22222", recent_nontmux_shell1),
            ("33333", recent_nontmux_shell2),
        ]);

        // Client IS attached - should prefer tmux shell for proper switching
        let decision = resolve_activation(
            "/Users/pete/Code/capacitor",
            Some(&state),
            &tmux_context_attached("capacitor"),
        );

        // Should pick the TMUX shell and use ActivateHostThenSwitchTmux
        assert!(
            matches!(
                decision.primary,
                ActivationAction::ActivateHostThenSwitchTmux { .. }
            ),
            "Expected ActivateHostThenSwitchTmux when tmux client attached, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_exact_non_tmux_beats_parent_tmux_when_attached() {
        // Exact path match should beat a tmux shell that only matches as a parent.
        let parent_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("code"),
            "2026-01-27T08:00:00Z",
        );

        let exact_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys001",
            ParentApp::Ghostty,
            None,
            "2026-01-27T07:00:00Z",
        );

        let state = make_shell_state(vec![("11111", parent_tmux_shell), ("22222", exact_shell)]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_attached("code"),
        );

        assert!(
            matches!(decision.primary, ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"),
            "Expected exact non-tmux shell to win over parent tmux shell, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_pid_tiebreaker_is_deterministic() {
        let lower_pid_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            "2026-01-27T10:00:00Z",
        );

        let higher_pid_shell = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys002",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z",
        );

        let state = make_shell_state(vec![
            ("11111", lower_pid_shell),
            ("22222", higher_pid_shell),
        ]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(
            matches!(decision.primary, ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"),
            "Expected higher PID shell to win deterministic tie-breaker, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_trace_reports_candidates_and_selection() {
        let shell_one = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            "2026-01-27T09:00:00Z",
        );

        let shell_two = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys002",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z",
        );

        let state = make_shell_state(vec![("11111", shell_one), ("22222", shell_two)]);
        let decision = resolve_activation_with_trace(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
            true,
        );

        let trace = decision.trace.expect("expected trace");
        assert_eq!(trace.selected_pid, Some(22222));
        assert_eq!(trace.candidates.len(), 2);
        assert_eq!(trace.candidates[0].pid, 22222);
    }

    #[test]
    fn test_trace_is_none_when_disabled() {
        let state = make_shell_state(vec![(
            "11111",
            make_shell_entry(
                "/Users/pete/Code/myproject",
                "/dev/ttys001",
                ParentApp::Terminal,
                None,
            ),
        )]);

        let decision = resolve_activation(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(decision.trace.is_none());
    }

    #[test]
    fn test_format_activation_trace_contains_core_fields() {
        let shell_one = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys001",
            ParentApp::Terminal,
            None,
            "2026-01-27T09:00:00Z",
        );

        let shell_two = make_shell_entry_with_time(
            "/Users/pete/Code/myproject",
            "/dev/ttys002",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z",
        );

        let state = make_shell_state(vec![("11111", shell_one), ("22222", shell_two)]);
        let decision = resolve_activation_with_trace(
            "/Users/pete/Code/myproject",
            Some(&state),
            &tmux_context_none(),
            true,
        );

        let trace = decision.trace.expect("expected trace");
        let formatted = format_activation_trace(trace);

        assert!(formatted.contains("ActivationTrace preferTmux="));
        assert!(formatted.contains("ActivationTrace policyOrder="));
        assert!(formatted.contains("ActivationTrace candidate pid="));
    }

    #[test]
    fn test_prefers_recent_shell_when_no_client_attached() {
        // Same scenario but no tmux client attached
        // Should use most recent shell (the old timestamp behavior)

        let old_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/capacitor",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("capacitor"),
            "2026-01-27T08:00:00Z", // Older
        );

        let recent_nontmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/capacitor",
            "/dev/ttys001",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z", // Newer
        );

        let state = make_shell_state(vec![
            ("11111", old_tmux_shell),
            ("22222", recent_nontmux_shell),
        ]);

        // No client attached - should use most recent (Ghostty)
        let decision = resolve_activation(
            "/Users/pete/Code/capacitor",
            Some(&state),
            &tmux_context_none(),
        );

        // Should pick the MORE RECENT shell (Ghostty)
        assert!(
            matches!(decision.primary, ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"),
            "Expected ActivateApp(Ghostty) when no tmux client, got {:?}",
            decision.primary
        );
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
    #[cfg(target_os = "macos")]
    fn test_paths_match_case_insensitive_on_macos() {
        assert!(paths_match(
            "/Users/Pete/Code/Project",
            "/users/pete/code/project"
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
    // Scenario: HOME exclusion from parent matching
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_home_shell_does_not_match_project() {
        // THE BUG: Shell at HOME was matching all projects because HOME is
        // technically a parent of everything under the user directory.
        // This caused "plink" project to match a shell at /Users/pete.

        let home_shell = make_shell_entry(
            "/Users/pete", // Shell at HOME
            "/dev/ttys007",
            ParentApp::Unknown,
            None,
        );

        let state = make_shell_state(vec![("87855", home_shell)]);

        // Clicking on /Users/pete/Code/plink should NOT match the HOME shell
        let decision = resolve_activation(
            "/Users/pete/Code/plink",
            Some(&state),
            &tmux_context_attached("plink"),
        );

        // Should NOT use the HOME shell - should fall through to tmux session
        assert!(
            matches!(decision.primary, ActivationAction::SwitchTmuxSession { .. }),
            "Expected SwitchTmuxSession (using tmux context) when HOME shell exists, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_home_shell_does_not_block_tmux_attach_when_detached() {
        let home_shell = make_shell_entry("/Users/pete", "/dev/ttys007", ParentApp::Ghostty, None);

        let state = make_shell_state(vec![("87855", home_shell)]);

        let decision = resolve_activation(
            "/Users/pete/Code/capacitor",
            Some(&state),
            &tmux_context_detached("capacitor"),
        );

        assert!(
            matches!(
                decision.primary,
                ActivationAction::LaunchTerminalWithTmux { .. }
            ),
            "Expected LaunchTerminalWithTmux when HOME shell exists and tmux client is detached, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_home_shell_still_matches_exact_home() {
        // Shell at HOME should still match when clicking HOME itself
        let home_shell = make_shell_entry("/Users/pete", "/dev/ttys007", ParentApp::Unknown, None);

        let state = make_shell_state(vec![("87855", home_shell)]);

        // Clicking on /Users/pete (HOME itself) should match
        let decision = resolve_activation("/Users/pete", Some(&state), &tmux_context_none());

        assert!(
            matches!(decision.primary, ActivationAction::ActivateByTty { .. }),
            "Expected ActivateByTty when clicking HOME with HOME shell, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_non_home_parent_still_matches() {
        // Parent matching should still work for non-HOME directories
        // e.g., /Code/monorepo shell should match /Code/monorepo/packages/app
        let monorepo_shell = make_shell_entry(
            "/Users/pete/Code/monorepo",
            "/dev/ttys003",
            ParentApp::Ghostty,
            None,
        );

        let state = make_shell_state(vec![("12345", monorepo_shell)]);

        // Clicking on a subpackage should match the monorepo shell
        let decision = resolve_activation(
            "/Users/pete/Code/monorepo/packages/app",
            Some(&state),
            &tmux_context_none(),
        );

        assert!(
            matches!(decision.primary, ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"),
            "Expected monorepo shell to match subpackage, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_paths_match_excluding_home_direct() {
        let home = "/Users/pete";

        // Exact match always works
        assert!(paths_match_excluding_home(home, home, home));

        // HOME as parent is excluded
        assert!(!paths_match_excluding_home(
            home,
            "/Users/pete/Code/project",
            home
        ));
        assert!(!paths_match_excluding_home(
            "/Users/pete/Code/project",
            home,
            home
        ));

        // Non-HOME parent matching still works
        assert!(paths_match_excluding_home(
            "/Users/pete/Code/repo",
            "/Users/pete/Code/repo/src",
            home
        ));
    }

    #[test]
    fn test_parent_tmux_shell_does_not_match_managed_worktree() {
        let parent_tmux_shell = make_shell_entry_with_time(
            "/Users/pete/Code/agentic-canvas",
            "/dev/pts/0",
            ParentApp::Tmux,
            Some("agentic-canvas"),
            "2026-01-27T10:00:00Z",
        );

        let state = make_shell_state(vec![("11111", parent_tmux_shell)]);
        let worktree_path = "/Users/pete/Code/agentic-canvas/.capacitor/worktrees/workstream-1";
        let decision = resolve_activation(
            worktree_path,
            Some(&state),
            &tmux_context_attached_no_session(),
        );

        assert!(
            matches!(decision.primary, ActivationAction::EnsureTmuxSession { ref session_name, .. } if session_name == "workstream-1"),
            "Expected EnsureTmuxSession for managed worktree path, got {:?}",
            decision.primary
        );
    }

    #[test]
    fn test_managed_worktree_shell_still_matches_same_worktree() {
        let worktree_shell = make_shell_entry_with_time(
            "/Users/pete/Code/agentic-canvas/.capacitor/worktrees/workstream-1/apps/web",
            "/dev/ttys007",
            ParentApp::Ghostty,
            None,
            "2026-01-27T10:00:00Z",
        );

        let state = make_shell_state(vec![("11111", worktree_shell)]);
        let worktree_path = "/Users/pete/Code/agentic-canvas/.capacitor/worktrees/workstream-1";
        let decision = resolve_activation(worktree_path, Some(&state), &tmux_context_none());

        assert!(
            matches!(decision.primary, ActivationAction::ActivateApp { ref app_name } if app_name == "Ghostty"),
            "Expected shell inside managed worktree to match same worktree, got {:?}",
            decision.primary
        );
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Normalize path tests
    // ─────────────────────────────────────────────────────────────────────────────

    #[test]
    fn test_normalize_path_strips_trailing_slash() {
        assert_eq!(normalize_path_for_actions("/foo/bar/"), "/foo/bar");
        assert_eq!(normalize_path_for_actions("/foo/bar"), "/foo/bar");
    }

    #[test]
    fn test_normalize_path_preserves_root() {
        assert_eq!(normalize_path_for_actions("/"), "/");
    }
}

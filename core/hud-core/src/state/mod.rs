//! Session State Detection (v3)
//!
//! Determines whether Claude Code is running and what it's doing for a given project.
//!
//! # Architecture: Sidecar Pattern
//!
//! Claude HUD follows a **sidecar philosophy**: we observe Claude Code without interfering.
//! The hook handler (`core/hud-hook/`) is authoritative for state transitions;
//! this module is a passive reader that applies staleness heuristics.
//!
//! ```text
//! Claude Code → Hook Script → State File + Lock Dir → This Module → Swift UI
//!     (user)      (writer)       (storage)              (reader)      (display)
//! ```
//!
//! # Two-Layer Liveness Detection
//!
//! We use two signals to determine if a session is active:
//!
//! 1. **Lock files** (primary): Directories in `~/.capacitor/sessions/{hash}.lock/`
//!    indicate a running session. Created by `spawn_lock_holder()` in the hook handler.
//!
//! 2. **Fresh record fallback**: If no lock exists but a state record is fresh
//!    (see [`types::STALE_THRESHOLD_SECS`]), trust it. Handles race conditions.
//!
//! # Active State Recovery
//!
//! When users interrupt Claude (Escape key, cancel), no hook event fires. To recover:
//! - Active states (Working, Waiting, Compacting) fall back to Ready after
//!   [`types::ACTIVE_STATE_STALE_SECS`] without updates.
//! - Aggressive threshold for fast UX; false positives self-correct on next hook event.
//!
//! # Module Structure
//!
//! - [`lock`]: Lock file detection and PID verification
//! - [`resolver`]: Fuses lock + state data to answer "is Claude running here?"
//! - [`store`]: Reads/writes the JSON state file (`~/.capacitor/sessions.json`)
//! - [`types`]: Data structures, staleness thresholds, canonical state mapping
//!
//! # Key Entry Points
//!
//! - [`is_session_running`]: Quick check for any active session at/under a path
//! - [`resolve_state_with_details`]: Full resolution with session ID and cwd
//! - [`StateStore`]: Low-level access to session records

mod cleanup;
pub(crate) mod lock;
mod resolver;
mod store;
pub(crate) mod types;

pub use cleanup::{run_startup_cleanup, CleanupStats};
pub use lock::{
    create_lock, get_lock_dir_path, get_lock_info, is_session_running, release_lock,
    update_lock_pid,
};
pub use resolver::{resolve_state, resolve_state_with_details, ResolvedState};
pub use store::StateStore;
pub use types::{
    HookEvent, HookInput, LastEvent, LockInfo, SessionRecord, ToolInput, ToolResponse,
};

/// Test helpers for creating locks - only available with test-helpers feature.
#[cfg(any(test, feature = "test-helpers"))]
pub use lock::tests_helper;

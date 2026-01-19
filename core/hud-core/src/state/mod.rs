pub(crate) mod lock;
mod resolver;
mod store;
mod transition;
pub(crate) mod types;

#[cfg(test)]
mod integration_tests;

pub use lock::{get_lock_info, is_session_running, reconcile_orphaned_lock};
pub use resolver::{resolve_state, resolve_state_with_details, ResolvedState};
pub use store::StateStore;
pub use transition::next_state;
pub use types::{ClaudeState, HookEvent, LockInfo, SessionRecord};

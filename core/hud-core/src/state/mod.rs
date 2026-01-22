//! State resolution: hook events + lock liveness + store snapshots.

pub(crate) mod lock;
mod resolver;
mod store;
pub(crate) mod types;

pub use lock::{get_lock_info, is_session_running};
pub use resolver::{resolve_state, resolve_state_with_details, ResolvedState};
pub use store::StateStore;
pub use types::{LastEvent, LockInfo, SessionRecord};

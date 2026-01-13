//! # hud-core
//!
//! Core library for Claude HUD, providing shared business logic for all clients
//! (Swift desktop, TUI, mobile server).
//!
//! ## Design Principles
//!
//! - **Synchronous**: No async runtime dependency. Clients can wrap with async if needed.
//! - **Not thread-safe**: Clients provide their own synchronization (`Mutex`, `RwLock`).
//! - **Graceful degradation**: Missing files return empty/default values, not errors.
//! - **Single source of truth**: All clients share these types and logic.
//! - **FFI-ready**: UniFFI annotations enable Swift, Kotlin, Python bindings.
//!
//! ## Quick Start
//!
//! ```rust,ignore
//! use hud_core::HudEngine;
//!
//! let mut engine = HudEngine::new()?;
//! let projects = engine.list_projects();
//! let states = engine.get_session_states();
//! ```

// UniFFI scaffolding for Swift/Kotlin/Python bindings
uniffi::setup_scaffolding!();

// Public modules
pub mod artifacts;
pub mod config;
pub mod engine;
pub mod error;
pub mod patterns;
pub mod projects;
pub mod sessions;
pub mod state;
pub mod stats;
pub mod types;

// Re-export commonly used items at crate root
pub use artifacts::*;
pub use config::*;
pub use engine::HudEngine;
pub use error::{HudError, HudFfiError, Result};
pub use patterns::*;
pub use projects::*;
pub use sessions::*;
pub use stats::*;
pub use types::*;

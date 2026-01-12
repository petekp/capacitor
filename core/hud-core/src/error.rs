//! Error types for hud-core operations.

use std::path::PathBuf;

// ═══════════════════════════════════════════════════════════════════════════════
// FFI-Compatible Error (for Swift/Kotlin/Python)
// ═══════════════════════════════════════════════════════════════════════════════

/// FFI-safe error type for use across language boundaries.
///
/// This simplified error type contains just an error message string,
/// making it compatible with UniFFI's error handling.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HudFfiError {
    #[error("{message}")]
    General { message: String },
}

impl From<String> for HudFfiError {
    fn from(message: String) -> Self {
        HudFfiError::General { message }
    }
}

impl From<&str> for HudFfiError {
    fn from(message: &str) -> Self {
        HudFfiError::General {
            message: message.to_string(),
        }
    }
}

impl From<HudError> for HudFfiError {
    fn from(err: HudError) -> Self {
        HudFfiError::General {
            message: err.to_string(),
        }
    }
}

// ═══════════════════════════════════════════════════════════════════════════════
// Internal Error (for Rust-only use)
// ═══════════════════════════════════════════════════════════════════════════════

/// All errors that can occur in hud-core operations.
///
/// This is the rich error type used internally in Rust code.
/// For FFI boundaries, use `HudFfiError` instead.
#[derive(Debug, thiserror::Error)]
pub enum HudError {
    // ─────────────────────────────────────────────────────────────────────
    // Configuration Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("Claude directory not found at {0}")]
    ClaudeDirNotFound(PathBuf),

    #[error("Configuration file malformed: {path}: {details}")]
    ConfigMalformed { path: PathBuf, details: String },

    #[error("Configuration write failed: {path}: {source}")]
    ConfigWriteFailed {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    // ─────────────────────────────────────────────────────────────────────
    // Project Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("Project not found: {0}")]
    ProjectNotFound(String),

    #[error("Project already pinned: {0}")]
    ProjectAlreadyPinned(String),

    #[error("Invalid project path: {path}: {reason}")]
    InvalidProjectPath { path: String, reason: String },

    // ─────────────────────────────────────────────────────────────────────
    // I/O Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("File not found: {0}")]
    FileNotFound(PathBuf),

    #[error("I/O error: {context}: {source}")]
    Io {
        context: String,
        #[source]
        source: std::io::Error,
    },

    #[error("JSON parsing error: {context}: {source}")]
    Json {
        context: String,
        #[source]
        source: serde_json::Error,
    },

    // ─────────────────────────────────────────────────────────────────────
    // Action Errors
    // ─────────────────────────────────────────────────────────────────────
    #[error("Command execution failed: {command}: {details}")]
    CommandFailed { command: String, details: String },

    #[error("Platform not supported for this operation: {0}")]
    UnsupportedPlatform(String),

    #[error("Not running inside tmux session")]
    NotInTmux,
}

/// Convenience type alias for Results using HudError.
pub type Result<T> = std::result::Result<T, HudError>;

// Conversion for string error compatibility
impl From<HudError> for String {
    fn from(err: HudError) -> String {
        err.to_string()
    }
}

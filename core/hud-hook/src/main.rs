//! hud-hook: CLI hook handler for Capacitor session state tracking.
//!
//! Rust binary that handles Claude Code hook events and updates session state.
//! Called directly by Claude Code hooks configured in ~/.claude/settings.json.
//!
//! ## Subcommands
//!
//! - `handle`: Main hook handler, reads JSON from stdin
//! - `cwd`: Shell CWD tracking (called by shell precmd hooks)
//! - `lock-holder`: Background daemon for lock management (spawned internally)

mod cwd;
mod handle;
mod lock_holder;
mod logging;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "hud-hook")]
#[command(about = "Capacitor session state tracker")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Handle a hook event (reads JSON from stdin)
    Handle,

    /// Report shell current working directory (called by shell precmd hooks)
    Cwd {
        /// Absolute path to current working directory
        #[arg(value_name = "PATH")]
        path: String,

        /// Shell process ID
        #[arg(value_name = "PID")]
        pid: u32,

        /// Terminal device path (e.g., /dev/ttys003)
        #[arg(value_name = "TTY")]
        tty: String,
    },

    /// Lock holder daemon (spawned by handle command)
    LockHolder {
        /// Session ID for this lock (v4 session-based locking)
        #[arg(long)]
        session_id: String,

        /// Working directory to monitor
        #[arg(long)]
        cwd: String,

        /// Claude process PID to monitor
        #[arg(long)]
        pid: u32,

        /// Lock directory path
        #[arg(long)]
        lock_dir: PathBuf,
    },
}

fn main() {
    let _logging_guard = logging::init();
    let cli = Cli::parse();

    match cli.command {
        Commands::Handle => {
            if let Err(e) = handle::run() {
                tracing::error!(error = %e, "hud-hook handle failed");
                std::process::exit(1);
            }
        }
        Commands::Cwd { path, pid, tty } => {
            // CWD tracking is non-critical - log errors but exit 0 to not disrupt shell
            if let Err(e) = cwd::run(&path, pid, &tty) {
                tracing::warn!(error = %e, "hud-hook cwd failed");
            }
        }
        Commands::LockHolder {
            session_id,
            cwd: cwd_path,
            pid,
            lock_dir,
        } => {
            lock_holder::run(&session_id, &cwd_path, pid, &lock_dir);
        }
    }
}

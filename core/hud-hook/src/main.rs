//! hud-hook: CLI hook handler for Claude HUD session state tracking.
//!
//! Rust binary that handles Claude Code hook events and updates session state.
//! Called directly by Claude Code hooks configured in ~/.claude/settings.json.
//!
//! ## Subcommands
//!
//! - `handle`: Main hook handler, reads JSON from stdin
//! - `lock-holder`: Background daemon for lock management (spawned internally)

mod handle;
mod lock_holder;

use clap::{Parser, Subcommand};
use std::path::PathBuf;

#[derive(Parser)]
#[command(name = "hud-hook")]
#[command(about = "Claude HUD session state tracker")]
#[command(version)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Handle a hook event (reads JSON from stdin)
    Handle,

    /// Lock holder daemon (spawned by handle command)
    LockHolder {
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
    let cli = Cli::parse();

    match cli.command {
        Commands::Handle => {
            if let Err(e) = handle::run() {
                eprintln!("hud-hook error: {}", e);
                std::process::exit(1);
            }
        }
        Commands::LockHolder { cwd, pid, lock_dir } => {
            lock_holder::run(&cwd, pid, &lock_dir);
        }
    }
}

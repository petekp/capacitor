//! hud-hook: CLI hook handler for Capacitor session state tracking.
//!
//! Rust binary that handles Claude Code hook events and updates session state.
//!
//! ## Subcommands
//!
//! - `serve`: local runtime service — receives hook events and serves runtime reads
//! - `cwd`: Shell CWD tracking (called by shell precmd hooks)

mod cwd;
mod handle;
mod hook_types;
mod logging;
mod runtime_client;
mod serve;

use clap::{Parser, Subcommand};

#[cfg(test)]
pub(crate) mod test_support {
    use std::sync::{Mutex, MutexGuard, OnceLock};

    static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

    pub(crate) fn env_lock() -> MutexGuard<'static, ()> {
        match ENV_LOCK.get_or_init(|| Mutex::new(())).lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

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
    /// Run the local runtime service for hook ingress and runtime reads
    Serve {
        /// Port to listen on
        #[arg(long, default_value = "7474")]
        port: u16,
    },

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
}

fn main() {
    let _logging_guard = logging::init();
    let cli = Cli::parse();

    match cli.command {
        Commands::Serve { port } => {
            if let Err(e) = serve::run(port) {
                tracing::error!(error = %e, "hud-hook serve failed");
                std::process::exit(1);
            }
        }
        Commands::Cwd { path, pid, tty } => {
            if let Err(e) = cwd::run(&path, pid, &tty) {
                eprintln!("hud-hook cwd failed: {e}");
                tracing::warn!(error = %e, "hud-hook cwd failed");
                std::process::exit(1);
            }
        }
    }
}

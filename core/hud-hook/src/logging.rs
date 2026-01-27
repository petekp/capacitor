//! Structured logging for hud-hook using tracing.
//!
//! Logs to `~/.capacitor/hud-hook-debug.{date}.log` with automatic daily rotation.
//! Keeps 7 days of logs. Log level can be controlled via `RUST_LOG` env var.
//!
//! Falls back to stderr logging if file appender creation fails.

use fs_err as fs;
use std::path::PathBuf;
use tracing_appender::rolling::{RollingFileAppender, Rotation};
use tracing_subscriber::{fmt, prelude::*, EnvFilter};

pub fn init() {
    let capacitor_dir = dirs::home_dir()
        .map(|h| h.join(".capacitor"))
        .unwrap_or_else(|| PathBuf::from("."));

    let _ = fs::create_dir_all(&capacitor_dir);

    let env_filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("hud_hook=debug,hud_core=warn"));

    match create_file_appender(&capacitor_dir) {
        Ok(file_appender) => {
            let (non_blocking, _guard) = tracing_appender::non_blocking(file_appender);

            // Leak the guard to keep it alive for program duration.
            // This is intentional - the hook is a short-lived process and we want
            // logs to flush before exit.
            std::mem::forget(_guard);

            tracing_subscriber::registry()
                .with(env_filter)
                .with(
                    fmt::layer()
                        .with_writer(non_blocking)
                        .with_timer(fmt::time::UtcTime::rfc_3339())
                        .with_ansi(false),
                )
                .init();
        }
        Err(_) => {
            // Fall back to stderr logging if file appender fails
            tracing_subscriber::registry()
                .with(env_filter)
                .with(
                    fmt::layer()
                        .with_writer(std::io::stderr)
                        .with_timer(fmt::time::UtcTime::rfc_3339())
                        .with_ansi(true),
                )
                .init();
        }
    }
}

fn create_file_appender(
    capacitor_dir: &PathBuf,
) -> Result<RollingFileAppender, tracing_appender::rolling::InitError> {
    RollingFileAppender::builder()
        .rotation(Rotation::DAILY)
        .filename_prefix("hud-hook-debug")
        .filename_suffix("log")
        .max_log_files(7)
        .build(capacitor_dir)
}

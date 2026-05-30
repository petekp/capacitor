//! OS-liveness sweep for the long-lived `hud-hook serve` process.
//!
//! ## Why this lives in hud-hook (not capacitor-core)
//!
//! The capacitor-core reducer must stay PURE and FS/OS-free so event replay is
//! deterministic. Probing the operating system for live processes is an
//! impure, time-dependent operation, so the actual `sysinfo` probe is owned by
//! the long-lived service shell here. The reducer only RECORDS the facts this
//! sweep produces (via `CoreRuntime::ingest_os_liveness`).
//!
//! ## What the sweep does
//!
//! On each GC tick we:
//! 1. Read the current snapshot to learn the set of tracked session pids and
//!    their stored `process_start_time` (PID-reuse discriminator).
//! 2. Do a SINGLE batched `sysinfo` refresh over only the distinct known pids
//!    (`ProcessesToUpdate::Some(&pids)`) with `ProcessRefreshKind::nothing()`
//!    so the probe stays cheap and bounded — we never enumerate all processes.
//! 3. For each known pid, record whether a live process exists and its OS
//!    start time, then hand the per-pid facts to the pure reducer, which
//!    applies PID-reuse gating (start-time mismatch => not alive).

use std::collections::BTreeSet;

use capacitor_core::{
    domain::{IngestOsLivenessCommand, OsLivenessEntry},
    CoreRuntime,
};
use chrono::{DateTime, Utc};
use sysinfo::{Pid, ProcessRefreshKind, ProcessesToUpdate, System};

/// Run one OS-liveness sweep against `runtime`, stamping the facts with
/// `reference_time` (sleep/wake-adjusted by the caller). Returns the number of
/// distinct pids probed, or an error string if the snapshot read or ingest
/// failed. A sweep with no tracked pids is a no-op (returns `Ok(0)`).
pub(crate) fn run_sweep(
    runtime: &CoreRuntime,
    reference_time: DateTime<Utc>,
) -> Result<usize, String> {
    let snapshot = runtime
        .app_snapshot()
        .map_err(|error| format!("os-liveness sweep snapshot read failed: {error}"))?;

    // Gather the distinct, real (pid > 0) session pids. Transcript-reconstructed
    // sessions carry pid 0 and have no OS process to probe — skip them.
    let mut distinct_pids: BTreeSet<u32> = BTreeSet::new();
    for session in &snapshot.sessions {
        if session.pid > 0 {
            distinct_pids.insert(session.pid);
        }
    }

    if distinct_pids.is_empty() {
        return Ok(0);
    }

    let entries = probe_pids(&distinct_pids);

    let command = IngestOsLivenessCommand {
        entries,
        recorded_at: reference_time.to_rfc3339(),
    };

    runtime
        .ingest_os_liveness(command)
        .map_err(|error| format!("os-liveness sweep ingest failed: {error}"))?;

    Ok(distinct_pids.len())
}

/// Probe exactly the supplied pids with a single batched `sysinfo` refresh and
/// return a per-pid liveness entry. Bounded cost: only the known pids are
/// refreshed (never the whole process table), mirroring `cwd::detect_proc_start`.
fn probe_pids(distinct_pids: &BTreeSet<u32>) -> Vec<OsLivenessEntry> {
    let sys_pids: Vec<Pid> = distinct_pids
        .iter()
        .map(|pid| Pid::from(*pid as usize))
        .collect();

    let mut sys = System::new();
    sys.refresh_processes_specifics(
        ProcessesToUpdate::Some(&sys_pids),
        true,
        ProcessRefreshKind::nothing(),
    );

    distinct_pids
        .iter()
        .map(|pid| {
            let sys_pid = Pid::from(*pid as usize);
            match sys.process(sys_pid) {
                Some(process) => OsLivenessEntry {
                    pid: *pid,
                    process_start_time: Some(process.start_time()),
                    alive: true,
                },
                None => OsLivenessEntry {
                    pid: *pid,
                    process_start_time: None,
                    alive: false,
                },
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    /// The sweep over an empty snapshot is a no-op and never errors.
    #[test]
    fn sweep_with_no_sessions_is_noop() {
        let runtime = CoreRuntime::new().expect("runtime");
        let probed = run_sweep(&runtime, Utc::now()).expect("sweep ok");
        assert_eq!(probed, 0);
    }

    /// A real, currently-live pid (this test process) sweeps to alive, and the
    /// recorded fact lands on the session via the pure reducer.
    #[test]
    fn sweep_marks_current_process_alive() {
        use capacitor_core::domain::{HookEventType, IngestHookEventCommand};

        let runtime = Arc::new(CoreRuntime::new().expect("runtime"));
        let my_pid = std::process::id();

        // Seed a session bound to this live pid through the normal ingest path.
        let outcome = runtime
            .ingest_hook_event(IngestHookEventCommand {
                event_id: "evt-live-1".to_string(),
                recorded_at: Utc::now().to_rfc3339(),
                event_type: HookEventType::UserPromptSubmit,
                session_id: "live-session".to_string(),
                pid: Some(my_pid),
                project_path: "/tmp/liveness-test".to_string(),
                cwd: Some("/tmp/liveness-test".to_string()),
                file_path: None,
                workspace_id: None,
                notification_type: None,
                stop_hook_active: None,
                tool_name: None,
                agent_id: None,
                teammate_name: None,
            })
            .expect("ingest hook event");
        assert!(outcome.ok);

        let probed = run_sweep(&runtime, Utc::now()).expect("sweep ok");
        assert_eq!(probed, 1);

        let snapshot = runtime.app_snapshot().expect("snapshot");
        let session = snapshot
            .sessions
            .iter()
            .find(|session| session.session_id == "live-session")
            .expect("session present");
        assert_eq!(
            session.os_process_alive,
            Some(true),
            "the current test process must read as OS-alive"
        );
    }

    /// A pid that cannot exist (0 is filtered; use a very high improbable pid)
    /// sweeps to not-alive.
    #[test]
    fn sweep_marks_absent_pid_dead() {
        use capacitor_core::domain::{HookEventType, IngestHookEventCommand};

        let runtime = Arc::new(CoreRuntime::new().expect("runtime"));
        // u32::MAX is not a valid live pid on macOS.
        let dead_pid = u32::MAX;

        let outcome = runtime
            .ingest_hook_event(IngestHookEventCommand {
                event_id: "evt-dead-1".to_string(),
                recorded_at: Utc::now().to_rfc3339(),
                event_type: HookEventType::UserPromptSubmit,
                session_id: "dead-session".to_string(),
                pid: Some(dead_pid),
                project_path: "/tmp/liveness-test".to_string(),
                cwd: Some("/tmp/liveness-test".to_string()),
                file_path: None,
                workspace_id: None,
                notification_type: None,
                stop_hook_active: None,
                tool_name: None,
                agent_id: None,
                teammate_name: None,
            })
            .expect("ingest hook event");
        assert!(outcome.ok);

        let probed = run_sweep(&runtime, Utc::now()).expect("sweep ok");
        assert_eq!(probed, 1);

        let snapshot = runtime.app_snapshot().expect("snapshot");
        let session = snapshot
            .sessions
            .iter()
            .find(|session| session.session_id == "dead-session")
            .expect("session present");
        assert_eq!(session.os_process_alive, Some(false));
    }
}

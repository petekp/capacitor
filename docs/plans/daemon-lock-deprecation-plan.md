# Daemon Lock Deprecation Plan

This document defines the migration path from filesystem lock directories
(`~/.capacitor/sessions/{session_id}-{pid}.lock/`) to daemon-owned liveness
(`process_liveness` table + `get_process_liveness` IPC).

## Goals

- Preserve correctness for existing installs during migration.
- Avoid user-visible regressions during daemon rollout.
- Provide a clear timeline for removing lock directories.

## Phase A — Compatibility (Alpha/Beta)

**Status:** current

- Hooks still create lock directories for compatibility.
- Daemon liveness is preferred when `CAPACITOR_DAEMON_ENABLED=1`.
- `hud-core` cleanup/lock checks use daemon liveness when available, with local fallback.
- Lock-holder uses daemon-aware identity verification where possible.

**Invariant:** Locks are still treated as authoritative when daemon is unavailable.

## Phase B — Read-only locks (Beta/Stable)

- Hooks stop creating new lock directories when daemon is healthy.
- Existing lock directories are read-only shims used only if:
  - daemon is down, or
  - daemon liveness query fails.
- UI diagnostics should surface whether lock dir mode is active.

**Gate to enter Phase B:**
- daemon liveness coverage verified across all hook event types.
- `process_liveness` replay is stable on daemon restart.

## Phase C — Removal (Stable+)

- Stop reading lock directories entirely.
- Remove lock cleanup logic from `hud-core`.
- Remove lock-holder subprocess from hooks.

**Gate to enter Phase C:**
- daemon auto-start + crash recovery stable.
- fallback policy updated (daemon required).
- migration telemetry shows lock fallback usage near zero.

## Implementation Checklist

- Add a daemon health check to decide whether to write locks.
- Define a daemon health probe (use `get_health` IPC with timeout).
- Consider exporting `CAPACITOR_DAEMON_LOCK_HEALTH=0/1/auto` from setup/launcher scripts (or Swift app).
  - `auto` disables lock writes only when the daemon health probe returns ok.
  - Hook installation currently normalizes commands to include `CAPACITOR_DAEMON_LOCK_HEALTH=auto`.
- Add a configuration gate to disable lock creation in Phase B.
- Update cleanup to skip lock removal when running in read-only/off modes.
- Add a diagnostic label indicating lock mode (full / read-only / disabled).
- Implement `CAPACITOR_DAEMON_LOCK_MODE` in hooks (full/read-only/off).
- Implement `CAPACITOR_DAEMON_LOCK_MODE` in `hud-core` cleanup (read-only/off skip deletions).

## Open Questions

- Should lock directories be retained for manual recovery tooling?
- Do we keep a debug flag to re-enable lock creation for troubleshooting?

# Agent Changelog

> This file helps coding agents understand project evolution, key decisions, and deprecated patterns. Updated: 2026-02-26

## Current State Summary

Capacitor is a macOS sidecar (SwiftUI + Rust/UniFFI) with a daemon-authoritative session model (`~/.capacitor/daemon/` + SQLite WAL). Terminal activation remains Rust-decision + Swift-execution, with outage handling preferring tmux recovery over new-window launch for `NO_TRUSTED_EVIDENCE` snapshots. Remote ingest now keeps a strict diagnostics allowlist (`activation_decision`, `activation_outcome`, IPC/routing errors) plus quick-feedback events, with app+worker duplicate throttling and scheduled D1 retention pruning to keep single-user telemetry bounded.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `README.md` (Data & privacy section) | "No data leaves your machine." | Remote feedback/telemetry ingest is supported when `CAPACITOR_FEEDBACK_API_URL` / `CAPACITOR_TELEMETRY_URL` + `CAPACITOR_INGEST_KEY` are configured. | 2026-02-15 (ingest shipped), reinforced 2026-02-26 (diagnostic allowlist restored) |

## Timeline

### 2026-02-26 — Telemetry Storage Control Pass (Throttling + Retention + Legacy Purge)

**What changed:**
- Added app-side duplicate throttling for remote diagnostic telemetry in `apps/swift/Sources/Capacitor/Utilities/Telemetry.swift` (2-second signature window on diagnostic event types).
- Added worker-side duplicate throttling in `services/ingest-worker/src/index.js` (`duplicate_throttled` responses for rapid duplicate diagnostics).
- Added scheduled D1 retention pruning via Worker cron in `services/ingest-worker/wrangler.toml` (`17 */6 * * *`), with tiered retention windows:
  - legacy non-allowlisted telemetry: 1 day
  - high-volume interaction telemetry: 30 days
  - diagnostics/submission telemetry: 90 days
- Executed one-time remote D1 cleanup to remove historical non-allowlisted noise (`125,063` rows deleted, `134,681 -> 9,618` rows).

**Why:**
Single-user telemetry volume was dominated by historical high-frequency debug events and expensive full scans, making Cloudflare dashboard numbers noisy and diagnostics less actionable.

**Agent impact:**
- Treat D1 `rows_read` as query-scan cost, not user-count proxy.
- Prefer indexed query predicates (`event_type`, `occurred_at`) before message text filters.
- Expect duplicate diagnostic events to be dropped in short windows by both app and worker.

**Deprecated:**
- Unbounded diagnostic emission to remote ingest.
- Keeping legacy non-allowlisted telemetry indefinitely in D1.

---

### 2026-02-26 — Remote Diagnostic Visibility Restored for External Debugging

**What changed:**
- Expanded remote telemetry allowlist on both app and worker to include:
  - `activation_decision`
  - `activation_outcome`
  - `daemon_ipc_error`
  - `routing_snapshot_refresh_error`
- Kept high-volume session/project churn events blocked for `/v1/telemetry`.
- Deployed Worker updates and validated production behavior with live probes:
  - allowed diagnostic event persisted (`200`)
  - non-allowlisted event dropped (`202`, `event_type_not_allowed`)

**Why:**
A prior ingest hardening pass had cut remote telemetry to quick-feedback-only, which removed terminal-routing visibility needed for external-user incident diagnosis.

**Agent impact:**
- External triage can now use Cloudflare D1 for activation-path diagnostics again.
- Do not assume remote telemetry contains all local debug events; it contains only the strict allowlist.

**Deprecated:**
- "Quick-feedback-only remote telemetry" assumption for post-2026-02-26 deployments.

---

### 2026-02-25 — `NO_TRUSTED_EVIDENCE` Launch Fallback Fix (Reuse tmux Before New Window)

**What changed:**
- Updated `launchTerminalWithAERSnapshot` in `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`:
  - when ARE snapshot is `status=unavailable` + `reasonCode=NO_TRUSTED_EVIDENCE`, launcher now tries fallback tmux session resolution first
  - if session is recoverable, primary action is rewritten from `.launchNewTerminal(...)` to `.ensureTmuxSession(...)`
- Added regression test:
  - `testLaunchTerminalNoTrustedEvidenceReusesRecoverableTmuxSessionBeforeLaunchingNewTerminal`

**Why:**
Project-card clicks could open a fresh Ghostty window even when a valid tmux session already existed, causing avoidable fan-out and wrong-context UX.

**Agent impact:**
- Preserve the `NO_TRUSTED_EVIDENCE -> tmux recovery first` behavior unless explicit product direction changes.
- For routing bugfixes, keep test-first guardrails in `TerminalLauncherTests` and validate both recovery and cold-start fallback paths.

**Deprecated:**
- Immediate launch-new-terminal fallback on `NO_TRUSTED_EVIDENCE` when tmux recovery is possible.

---

### 2026-02-23 (Local Working Tree) — Ghostty Tab Routing Race Condition Fix

**What changed:**
- Made `TerminalLauncher` Ghostty activation pipeline fully `async`.
- Implemented an `async` deterministic retry loop inside `activateGhosttyWithAXRouting` (up to 5 attempts, 100ms apart) when a specific project path or tmux session is targeted.

**Why:**
`tmux switch-client` executes instantaneously, but Ghostty's macOS Accessibility (AX) API tree takes a few milliseconds to update the tab title. The previous synchronous logic was querying the AX tree immediately after the `tmux` command, reading stale state, failing to find the expected tab, and falling back to a generic window raise instead of pressing the correct tab. 

**Agent impact:**
- When relying on UI accessibility APIs (like `AXUIElement`) immediately following an external state change (like a CLI command or IPC), implement an `async` polling/retry loop to allow the UI state to settle.
- Maintain the asynchronous nature of the Ghostty activation pipeline.

**Deprecated:**
- Synchronous polling of the Ghostty AX tree immediately after a `tmux` state change.

---

### 2026-02-23 (Local Working Tree) — Ghostty Tab Routing Stabilization + Launcher Cleanup

**What changed:**
- Stabilized Ghostty tab focus after live QA reproduced wrong-tab behavior despite `route=tab_press` logs:
  - `focusTab` order changed from `press -> raise` to `raise -> press` in `apps/swift/Sources/Capacitor/Models/GhosttyAXReader.swift`.
- Extended deterministic match signals in `bestGhosttyTabMatch(...)`:
  - Ellipsized paths (`…/Code/...`) and tmux session-style tab titles (`assistant-ui:1:...`) now map to project cards.
- Cleaned up duplicated launcher script helpers and fixed `runBashScriptWithResult` large-output deadlock risk in `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`.
- Revalidated with focused tests (`GhosttyAXReaderTests`, `TerminalLauncherTests`) plus live marker-bounded AX probes.

**Why:**
Initial tab-routing rollout closed the architecture gap but still had a UX-critical runtime bug: Ghostty could revert to the previously focused tab after successful AX press. Additional matcher coverage and process-execution cleanup were needed to make behavior reliable under real user conditions.

**Agent impact:**
- Treat Ghostty focus ordering as semantically important; do not reorder `raise -> press` without re-running live AX checks.
- Use tmux-style title matching and ellipsized-path matching as first-class deterministic signals in Ghostty fallback routing.
- Keep the large-output process execution path in `runBashScriptWithResult` non-blocking; this is now guarded by an explicit deadlock regression test.

**Deprecated:**
- `AXPress(tab)` followed by `AXRaise(window)` in Ghostty focus paths.
- Path-only tab matching assumptions for Ghostty (tmux-title tabs are now valid deterministic candidates).
- Duplicated top-level shell/AppleScript helper implementations in `TerminalLauncher.swift`.

---

### 2026-02-23 (Local Working Tree) — Deterministic Ghostty AX Tab Routing (Hard Cut)

**What changed:**
- Expanded `apps/swift/Sources/Capacitor/Models/GhosttyAXReader.swift` with tab-aware AX integration (`readWindows`, `focusTab`, `raiseWindow`) and deterministic matcher (`bestGhosttyTabMatch`).
- Replaced Ghostty multi-window activation guesswork with project-aware AX tab routing in `TerminalLauncher.activateGhosttyWithAXRouting`.
- Threaded `projectPath` through activation execution where needed (`activateByTty(..., projectPath:)` and Ghostty-specific `.activateApp("Ghostty")` handling).
- Replaced old `TerminalDiscovery` Ghostty surface (`isGhosttyRunning`, `countGhosttyWindows`) with `ghosttyWindowState()` + `activateGhostty(projectPath:)`.
- Removed legacy Ghostty codepaths and tests tied to window-title/path ranking heuristics.

**Why:**
Ghostty multi-tab/multi-window activation was the biggest reliability gap: app-level activation could foreground the wrong window and tab, forcing manual switching.

**Agent impact:**
- Use `GhosttyAXReader`, `bestGhosttyTabMatch(...)`, and tab-first route resolution as the Ghostty targeting source of truth.
- Do not reintroduce window-title-only Ghostty routing or process-tree owner-PID Ghostty targeting.
- Keep the documented fail-open fallback behavior in `activateGhosttyWithAXRouting` explicit and intentional.
- Validate Ghostty routing with `GhosttyAXReaderTests`, `ActivationActionExecutorTests`, and `TerminalLauncherTests`.

**Verification evidence:**
- Focused Swift test suites (`GhosttyAXReaderTests`, `TerminalLauncherTests`, `ActivationActionExecutorTests`) cover tab matching + route fallback behavior.
- Live AX probes confirm Ghostty exposes tab group metadata and `AXPress` on tabs for deterministic selection.

---

### 2026-02-22 — Session-State Gate Hardening + Reliability Cleanup

**What changed:** Added canonical session-state release matrix, focused P0 gate suites (`session_state_mapping_gate`, `session_state_release_gate`), CI gate script (`scripts/ci/session-state-gate.sh`), and manual evidence template. Followed by stop-gate/session-refresh/ready-chime reliability fixes and dead-code sweep (including unused Variablur dependency).

**Why:** Repeated state drift symptoms required explicit release-blocking criteria with automated enforcement.

**Agent impact:**
- Treat `docs/SESSION_STATE_RELEASE_MATRIX.md` as canonical release contract.
- Run `bash scripts/ci/session-state-gate.sh` before release cut.

---

### 2026-02-22 — Non-Demo AX UI Smoke Gate

**What changed:** Added `scripts/ci/non-demo-ax-smoke.sh` and wired requirement into `docs/PRE_RELEASE_CHECKLIST.md`.

**Why:** Demo automation can mask real runtime behavior.

**Agent impact:**
- Run non-demo AX smoke for release confidence.
- Keep details-flow checks in frontier profile where details are enabled.

---

### 2026-02-22 — Shared Project-Card Drop + IPC Client Deduplication

**What changed:** Consolidated drag/drop behavior and daemon IPC client code paths.

**Why:** Duplicate paths were drifting and increasing maintenance cost.

**Agent impact:**
- Change drop behavior in shared delegate path.
- Update IPC behavior in shared protocol/client surfaces first.

---

### 2026-02-21 — Unified Project-State Resolution + Agent Observability Toolkit

**What changed:** Unified active-project/session resolution and introduced canonical agent observability workflow (`scripts/dev/agent-observe.sh` + runbook).

**Why:** Cross-process debugging was too slow and inconsistent.

**Agent impact:**
- Use `scripts/dev/agent-observe.sh` as default runtime-debug entrypoint.

---

### 2026-02-20 — Hook Event Expansion + DRY Skip-Through Pattern

**What changed:** Added newer Claude hook variants and moved repetitive skip arms to a DRY skip-through pattern while preserving exhaustive mapper sites.

**Why:** Informational hook growth created mapper maintenance drag.

**Agent impact:**
- Keep canonical parser/mapping sites exhaustive.
- Avoid reintroducing repetitive skip-only match arms.

---

### 2026-02-20 — Alpha-First Channel/Profile Runtime Context

**What changed:** Added persistent runtime context (`channel` + `profile`) with stable/frontier restart workflows.

**Why:** Needed stable public-alpha posture alongside frontier experimentation.

**Agent impact:**
- Daily workflow: `./scripts/dev/restart-current.sh`.
- Explicit context switching: `restart-alpha-stable.sh` / `restart-alpha-frontier.sh`.

---

### 2026-02-19 — SMAppService Daemon Registration Migration

**What changed:** Migrated daemon lifecycle from manual launchd primary path to bundled `SMAppService` flow, then hardened startup/health/replay.

**Why:** Better macOS-native lifecycle and attribution.

**Agent impact:**
- Treat bundled registration as primary lifecycle path.

---

### 2026-01-30 — Daemon-Authoritative State Service (ADR-005)

**What changed:** Removed file-based multi-writer state in favor of daemon-owned reducer + SQLite replay model.

**Why:** JSON multi-writer model was race-prone.

**Agent impact:**
- Daemon snapshots are authoritative.
- Fix state transitions in daemon reducer/state layers first.

---

### 2026-01-14 — Sidecar Architecture Contract (ADR-003)

**What changed:** Locked in sidecar boundary: observe/orchestrate Claude workflows without replacing terminal/editor.

**Why:** Preserves product scope and avoids auth/API coupling.

**Agent impact:**
- Read from `~/.claude/`, write to `~/.capacitor/`.
- Use `claude` CLI subprocess path for AI interactions.

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Assume remote telemetry still contains every local debug event or all historical event types | Use the strict allowlist contract (`quick_feedback_*`, activation diagnostics, IPC/routing errors) for external incident analysis | 2026-02-26 |
| Run production D1 diagnostics with message-only scans as default | Query by indexed fields first (`event_type`, `occurred_at`), then narrow by message/project | 2026-02-26 |
| Emit repeated identical diagnostic events to remote ingest on tight loops | Rely on app+worker duplicate throttling and design event payloads for meaningful state transitions | 2026-02-26 |
| Call Ghostty tab focus as `press -> raise` | Call Ghostty tab focus as `raise -> press` | 2026-02-23 (local working tree, post-live QA stabilization) |
| Assume Ghostty deterministic tab matches come only from absolute/tilde path titles | Also match tmux-style session-prefixed tab titles (`<project-slug>:`) and ellipsized path titles | 2026-02-23 (local working tree, post-live QA stabilization) |
| Maintain duplicate script-run helper implementations at both file-scope and type-scope in `TerminalLauncher.swift` | Keep a single canonical implementation path for script execution helpers | 2026-02-23 (local working tree, cleanup pass) |
| Use `activateGhosttyWithHeuristic` / Ghostty window-count-only activation | Use `activateGhosttyWithAXRouting` + `GhosttyAXReader` tab-first matching/press + raise fallback | 2026-02-23 (local working tree) |
| Use Ghostty process-tree owner PID targeting (`ghosttyOwnerPid` / `activateGhosttyProcessOwningTTY`) | Use AX window+tab snapshots + deterministic path matching | 2026-02-23 (local working tree) |
| Use `TerminalDiscovery.isGhosttyRunning()` + `countGhosttyWindows()` | Use `ghosttyWindowState()` + `activateGhostty(projectPath:)` | 2026-02-23 (local working tree) |
| Treat `updated_at` churn as stop-gate origin | Use transition-origin timestamp + bounded grace evaluation | 2026-02-21 |
| Add explicit skip match arms for every informational hook variant | Use skip-through catch-all where appropriate, keep mapper sites exhaustive | 2026-02-20 |
| Use demo mode as release reliability evidence for UI state flows | Use non-demo AX smoke (`scripts/ci/non-demo-ax-smoke.sh`) | 2026-02-22 |
| Manually manage daemon launchd plists as primary path | Use bundled SMAppService lifecycle | 2026-02-19 |
| Read/write legacy session JSON state directly | Use daemon IPC snapshots + reducer pipeline | 2026-01-30 |
| Call Anthropic APIs directly from app runtime | Invoke `claude` CLI subprocess path | 2026-01-14 |

## Trajectory

1. Terminal activation is moving from heuristic app activation to deterministic, evidence-backed tab/window targeting (Ghostty AX routing is now in stabilization/hardening phase, not initial rollout).
2. Reliability gates are becoming release-blocking contracts (session-state + non-demo AX smoke).
3. External-debug telemetry is moving toward low-noise, high-signal ingestion (strict allowlist + duplicate throttling + scheduled retention), rather than firehose ingest.
4. Short-term hardening focus is preserving runtime-proven Ghostty AX semantics and tightening documentation parity for privacy/telemetry behavior.

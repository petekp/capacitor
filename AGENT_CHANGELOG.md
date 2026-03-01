# Agent Changelog

> This file helps coding agents understand project evolution, key decisions, and deprecated patterns. Updated: 2026-03-01

## Current State Summary

Capacitor is a macOS sidecar (SwiftUI + Rust/UniFFI) with a **direct-core snapshot architecture** — hooks ingest events into `capacitor-core`, which projects state to `~/.capacitor/runtime/app_snapshot.json`. The daemon, SQLite WAL, and IPC socket are gone. Terminal activation is Rust-decision + Swift-execution, with tmux recovery overriding any resolver action when reason is `NO_TRUSTED_EVIDENCE` or `TMUX_SESSION_DETACHED` and a tmux session exists. When Ghostty is already running, activation opens a new tab (System Events Cmd+T) instead of a new window. Diagnostics are consolidated into a single CLI (`./scripts/dev/agent-observe.sh`) with self-sufficient commands that read the snapshot file directly. Remote ingest keeps a strict diagnostics allowlist with app+worker duplicate throttling and scheduled D1 retention pruning.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `README.md` (Data & privacy section) | "No data leaves your machine." | Remote feedback/telemetry ingest is supported when `CAPACITOR_FEEDBACK_API_URL` / `CAPACITOR_TELEMETRY_URL` + `CAPACITOR_INGEST_KEY` are configured. | 2026-02-15 |
| Previous AGENT_CHANGELOG (Current State Summary) | "daemon-authoritative session model (`~/.capacitor/daemon/` + SQLite WAL)" | Daemon replaced by direct-core snapshot (`~/.capacitor/runtime/app_snapshot.json`). No daemon, no SQLite, no IPC socket. | 2026-02-28 (RW-001/002 completed) |

## Timeline

### 2026-03-01 — Tmux Auto-Attach + Ghostty New Tab on Card Click

**What changed:**
- `TerminalLauncher.launchTerminalWithAERSnapshot` (line 822): broadened tmux recovery override to fire on both `NO_TRUSTED_EVIDENCE` and `TMUX_SESSION_DETACHED`, and removed the `.launchNewTerminal`-only guard so any primary action (including `.activatePriorityFallback`) gets overridden to `.ensureTmuxSession` when a tmux session exists.
- `TerminalLauncher.launchTerminalWithTmuxSession`: when Ghostty is already running (`isGhosttyRunningInternal()`), creates a new tab via System Events (Cmd+T + keystroke tmux command + Return) instead of `open -na` which spawned a new window.
- `DiagnosticsSummary` skip counter fields (`events_skipped`, `stale_events_skipped`, `informational_events_skipped`, `reducer_events_skipped`) now have `#[serde(default)]` for backward-compatible parsing of older snapshots during live upgrades.

**Why:**
Clicking a project card when no tmux client was attached would either focus a random Ghostty window (`activatePriorityFallback`) or open a brand new Ghostty window. Users expected the existing Ghostty window to open a tab attached to the correct tmux session.

**Agent impact:**
- The tmux recovery override at line 822 is now reason-code-based, not action-type-based. It fires for ANY primary action when the reason suggests no trusted evidence or a detached session.
- New Rust `DiagnosticsSummary` fields should always use `#[serde(default)]` for forward/backward snapshot compatibility.
- The System Events keystroke approach for Ghostty tabs requires Accessibility permission (one-time macOS consent).

**Deprecated:**
- Opening a new Ghostty window via `open -na` when Ghostty is already running.
- Guard-on-`.launchNewTerminal` for `NO_TRUSTED_EVIDENCE` tmux recovery (now fires regardless of primary action).

---

### 2026-03-01 — Diagnostics Single Pane of Glass

**What changed:**
- Deleted dead daemon/SQLite diagnostic artifacts: `observe-sql`, `observe-tail-daemon-stderr/stdout`, `/routing-rollout` endpoint, `docs/transparent-ui/` directory, all 18 Makefile `observe-*` targets.
- Made `agent-observe.sh` self-sufficient: `briefing`, `snapshot`, `check` commands read the snapshot file directly instead of requiring the Node transparent-ui-server.
- Added new commands: `diagnose` (one-shot full diagnostic), `freshness` (snapshot age), `errors` (recent error lines from debug log), `hooks` (hook binary + heartbeat status), `activation-traces` (recent activation decision traces).
- Promoted `DiagnosticsSnapshotLogger` from `#if DEBUG` to release builds with 5MB rotation.
- Added skip counters (`events_skipped`, `stale_events_skipped`, `informational_events_skipped`, `reducer_events_skipped`) to `DiagnosticsSummary` for event loss visibility.
- Added activation trace persistence to debug log.
- Merged `agent-observability-runbook.md` into `debugging-guide.md`. Deleted the runbook.

**Why:**
5 overlapping diagnostic layers accumulated during the daemon → direct-core transition. Agents needed a single entry point that works without external server dependencies.

**Agent impact:**
- Use `./scripts/dev/agent-observe.sh diagnose` as the one-shot diagnostic entry point.
- Do not reference Makefile `observe-*` targets (deleted).
- Do not assume transparent-ui-server is required for diagnostics (it's optional for browser exploration only).
- `debugging-guide.md` is the single canonical debugging doc.

**Deprecated:**
- Makefile `observe-*` targets (deleted).
- `agent-observability-runbook.md` (merged into `debugging-guide.md`).
- `#if DEBUG` gating of `DiagnosticsSnapshotLogger` (now always active with rotation).
- Requiring transparent-ui-server for basic diagnostic queries.

---

### 2026-02-28 — Test Surface Rewrite (RW-058 through RW-099)

**What changed:**
42 rewrite slices systematically restructured the Swift test suite:
- Eliminated local scenario structs in favor of shared `LabeledExpectationScenario<Input, Expected>` generic.
- Consolidated assertion helpers (`assertSingleAction`, `assertSingleActivationResult`, `assertEventually`, `scenarioContext`).
- Created shared harnesses: `SetupScenarioHarness`, `RuntimeClientTests` fixtures, non-setup test harness expansion.
- Typed setup step identifiers replacing stringly-typed keys.
- Scenario-struct budget ratchet in CI (`scripts/ci/test-surface-audit.sh`).
- BATS CLI test consolidation.
- Trailing-comma lint normalization across all test files.

**Why:**
Test files had accumulated ad-hoc scenario structs, duplicated assertion logic, and inconsistent patterns across 20+ test classes. The rewrite brought them under a single governance model with CI enforcement.

**Agent impact:**
- Use `LabeledExpectationScenario<Input, Expected>` for scenario-driven tests, not local structs.
- Use `scenarioContext()` for test failure messages that identify which scenario failed.
- Use shared assertion helpers rather than inline `XCTAssert` sequences.
- CI enforces a budget on local scenario structs — don't add new ones.
- Follow existing test patterns in `SetupScenarioHarness` and `TerminalLauncherTests` for new test code.

**Deprecated:**
- Local `struct Scenario { ... }` definitions in test files (use `LabeledExpectationScenario`).
- Ad-hoc assertion sequences (use shared helpers).
- Stringly-typed setup step identifiers.

---

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

**Why:**
Project-card clicks could open a fresh Ghostty window even when a valid tmux session already existed, causing avoidable fan-out and wrong-context UX.

**Agent impact:**
- Preserve the `NO_TRUSTED_EVIDENCE -> tmux recovery first` behavior unless explicit product direction changes.
- For routing bugfixes, keep test-first guardrails in `TerminalLauncherTests` and validate both recovery and cold-start fallback paths.

**Deprecated:**
- Immediate launch-new-terminal fallback on `NO_TRUSTED_EVIDENCE` when tmux recovery is possible.

---

### 2026-02-23 — Ghostty Tab Routing Race Condition Fix

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

### 2026-02-23 — Ghostty Tab Routing Stabilization + Launcher Cleanup

**What changed:**
- Stabilized Ghostty tab focus after live QA reproduced wrong-tab behavior despite `route=tab_press` logs:
  - `focusTab` order changed from `press -> raise` to `raise -> press` in `apps/swift/Sources/Capacitor/Models/GhosttyAXReader.swift`.
- Extended deterministic match signals in `bestGhosttyTabMatch(...)`:
  - Ellipsized paths (`…/Code/...`) and tmux session-style tab titles (`assistant-ui:1:...`) now map to project cards.
- Cleaned up duplicated launcher script helpers and fixed `runBashScriptWithResult` large-output deadlock risk.

**Why:**
Initial tab-routing rollout closed the architecture gap but still had a UX-critical runtime bug: Ghostty could revert to the previously focused tab after successful AX press.

**Agent impact:**
- Treat Ghostty focus ordering as semantically important; do not reorder `raise -> press` without re-running live AX checks.
- Use tmux-style title matching and ellipsized-path matching as first-class deterministic signals in Ghostty fallback routing.

**Deprecated:**
- `AXPress(tab)` followed by `AXRaise(window)` in Ghostty focus paths.
- Path-only tab matching assumptions for Ghostty (tmux-title tabs are now valid deterministic candidates).

---

### 2026-02-23 — Deterministic Ghostty AX Tab Routing (Hard Cut)

**What changed:**
- Expanded `GhosttyAXReader.swift` with tab-aware AX integration (`readWindows`, `focusTab`, `raiseWindow`) and deterministic matcher (`bestGhosttyTabMatch`).
- Replaced Ghostty multi-window activation guesswork with project-aware AX tab routing.
- Replaced old `TerminalDiscovery` Ghostty surface with `ghosttyWindowState()` + `activateGhostty(projectPath:)`.

**Why:**
Ghostty multi-tab/multi-window activation was the biggest reliability gap.

**Agent impact:**
- Use `GhosttyAXReader`, `bestGhosttyTabMatch(...)`, and tab-first route resolution as the Ghostty targeting source of truth.
- Do not reintroduce window-title-only Ghostty routing or process-tree owner-PID targeting.

---

### 2026-02-22 — Session-State Gate Hardening + Reliability Cleanup

**What changed:** Added canonical session-state release matrix, focused P0 gate suites (`session_state_mapping_gate`, `session_state_release_gate`), CI gate script (`scripts/ci/session-state-gate.sh`), and manual evidence template.

**Why:** Repeated state drift symptoms required explicit release-blocking criteria with automated enforcement.

**Agent impact:**
- Treat `docs/SESSION_STATE_RELEASE_MATRIX.md` as canonical release contract.
- Run `bash scripts/ci/session-state-gate.sh` before release cut.

---

### 2026-02-22 — Non-Demo AX UI Smoke Gate

**What changed:** Added `scripts/ci/non-demo-ax-smoke.sh` and wired requirement into `docs/PRE_RELEASE_CHECKLIST.md`.

**Agent impact:**
- Run non-demo AX smoke for release confidence.

---

### 2026-02-21 — Unified Project-State Resolution + Agent Observability Toolkit

**What changed:** Unified active-project/session resolution and introduced canonical agent observability workflow (`scripts/dev/agent-observe.sh` + runbook).

**Agent impact:**
- Use `scripts/dev/agent-observe.sh` as default runtime-debug entrypoint.

---

### 2026-02-20 — Hook Event Expansion + DRY Skip-Through Pattern

**What changed:** Added newer Claude hook variants and moved repetitive skip arms to a DRY skip-through pattern while preserving exhaustive mapper sites.

**Agent impact:**
- Keep canonical parser/mapping sites exhaustive.
- Avoid reintroducing repetitive skip-only match arms.

---

### 2026-02-20 — Alpha-First Channel/Profile Runtime Context

**What changed:** Added persistent runtime context (`channel` + `profile`) with stable/frontier restart workflows.

**Agent impact:**
- Daily workflow: `./scripts/dev/restart-current.sh`.
- Explicit context switching: `restart-alpha-stable.sh` / `restart-alpha-frontier.sh`.

---

### 2026-02-19 — SMAppService Daemon Registration Migration

**What changed:** Migrated daemon lifecycle from manual launchd primary path to bundled `SMAppService` flow, then hardened startup/health/replay.

**Agent impact:**
- Treat bundled registration as primary lifecycle path.

---

### 2026-01-30 — Daemon-Authoritative State Service (ADR-005) [SUPERSEDED]

**What changed:** Removed file-based multi-writer state in favor of daemon-owned reducer + SQLite replay model.

**⚠️ Note:** This architecture was subsequently replaced by the direct-core snapshot model (RW-001/002, Feb 2026). The daemon, SQLite WAL, and IPC socket no longer exist.

**Agent impact:**
- ~~Daemon snapshots are authoritative.~~ → Runtime snapshot file at `~/.capacitor/runtime/app_snapshot.json` is authoritative.
- Fix state transitions in `core/capacitor-core/src/reduce/` reducer layers.

---

### 2026-01-14 — Sidecar Architecture Contract (ADR-003)

**What changed:** Locked in sidecar boundary: observe/orchestrate Claude workflows without replacing terminal/editor.

**Agent impact:**
- Read from `~/.claude/`, write to `~/.capacitor/`.
- Use `claude` CLI subprocess path for AI interactions.

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Open new Ghostty window via `open -na` when Ghostty is running | Use System Events Cmd+T to create a new tab in existing Ghostty | 2026-03-01 |
| Guard tmux recovery on `.launchNewTerminal` action type | Fire tmux recovery on reason code (`NO_TRUSTED_EVIDENCE`, `TMUX_SESSION_DETACHED`) regardless of primary action | 2026-03-01 |
| Add new `DiagnosticsSummary` fields without `#[serde(default)]` | Always use `#[serde(default)]` for new optional/additive fields in snapshot types | 2026-03-01 |
| Use Makefile `observe-*` targets for diagnostics | Use `./scripts/dev/agent-observe.sh` directly | 2026-03-01 |
| Require transparent-ui-server for basic diagnostic queries | CLI commands read snapshot file directly | 2026-03-01 |
| Gate `DiagnosticsSnapshotLogger` behind `#if DEBUG` | Always active in release builds with 5MB rotation | 2026-03-01 |
| Define local `struct Scenario` in test files | Use `LabeledExpectationScenario<Input, Expected>` | 2026-02-28 |
| Write ad-hoc assertion sequences in tests | Use shared helpers (`assertSingleAction`, `assertSingleActivationResult`, `scenarioContext`) | 2026-02-28 |
| Reference daemon IPC, SQLite WAL, or `~/.capacitor/daemon/` | Architecture is now direct-core snapshot at `~/.capacitor/runtime/app_snapshot.json` | 2026-02-28 |
| Assume remote telemetry contains every local debug event | Use strict allowlist contract (`quick_feedback_*`, activation diagnostics, IPC/routing errors) | 2026-02-26 |
| Run production D1 diagnostics with message-only scans | Query by indexed fields first (`event_type`, `occurred_at`) | 2026-02-26 |
| Call Ghostty tab focus as `press -> raise` | Call Ghostty tab focus as `raise -> press` | 2026-02-23 |
| Use window-title-only Ghostty routing or process-tree PID targeting | Use `GhosttyAXReader` + `bestGhosttyTabMatch` tab-first matching | 2026-02-23 |
| Use demo mode as release reliability evidence | Use non-demo AX smoke (`scripts/ci/non-demo-ax-smoke.sh`) | 2026-02-22 |
| Manually manage daemon launchd plists | Use bundled SMAppService lifecycle | 2026-02-19 |
| Read/write legacy session JSON state directly | Use runtime snapshot via `capacitor-core` reducer pipeline | 2026-01-30 |
| Call Anthropic APIs directly from app runtime | Invoke `claude` CLI subprocess path | 2026-01-14 |

## Trajectory

1. **Architecture is stabilized on direct-core snapshots.** The daemon → direct-core migration is complete. All state flows through `capacitor-core` → snapshot file → Swift reads.
2. **Terminal activation is converging on tab-level precision.** Ghostty AX tab routing is in stabilization; tmux auto-attach now handles the detached-client edge case; new-tab-instead-of-new-window improves multi-session UX.
3. **Diagnostics are consolidated.** Single CLI entry point (`agent-observe.sh`), self-sufficient commands, activation traces in debug log, skip counters for event loss visibility.
4. **Test infrastructure is governed.** CI-enforced scenario-struct budgets, shared harnesses, typed identifiers. New test code should follow these patterns.
5. **Remote telemetry is low-noise, high-signal.** Strict allowlist + throttling + retention, not firehose.

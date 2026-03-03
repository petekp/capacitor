# Agent Changelog

> This file helps coding agents understand project evolution, key decisions, and deprecated patterns. Updated: 2026-03-02

## Current State Summary

Capacitor is a macOS sidecar (SwiftUI + Rust/UniFFI) with a **direct-core snapshot architecture** — hooks ingest events into `capacitor-core`, which projects state to `~/.capacitor/runtime/app_snapshot.json`. Terminal activation is a simple three-branch Swift flow (resolve tmux client → switch-client or launch new tab → AX focus) in ~800 lines. Ghostty is the only supported terminal. New tabs use `open -a Ghostty.app /path` (no `-n` flag = no dock icon duplication) + AppleScript to type tmux commands. The Rust resolver is no longer called during card clicks. AX tab routing (`GhosttyAXReader` + `bestGhosttyTabMatch`) handles tab focus after session switches, with stale-TTY detection returning false when `window_raise` has no matched tab. Diagnostics are consolidated into `./scripts/dev/agent-observe.sh`.

## Stale Information Detected

| Location | States | Reality | Since |
|----------|--------|---------|-------|
| `README.md` (Terminal support table, lines 27-36) | Claims iTerm2 and Terminal.app support with full workflow parity | Only Ghostty is supported; multi-terminal fallback code deleted | 2026-03-02 |
| `README.md` (Data & privacy section) | "No data leaves your machine." | Remote feedback/telemetry ingest is supported when `CAPACITOR_FEEDBACK_API_URL` / `CAPACITOR_TELEMETRY_URL` + `CAPACITOR_INGEST_KEY` are configured. | 2026-02-15 |
| `.claude/docs/terminal-activation-ux-spec.md` | Describes managed-TTY affinity (B6), auto-attach (B9/D-010), bookmark system (D-005/D-007-D-009) | All removed in simplification. Current flow has no managed TTY state, no bookmarks, no auto-attach path | 2026-03-02 |
| `.claude/migration/terminal-activation-v2/DECISIONS.md` | Describes D-002 (managed TTY), D-005 (bookmark), D-007-D-009 (orphan detection), D-010 (auto-attach) | All superseded by simplification DECISIONS.md in `terminal-activation-simplification/` | 2026-03-02 |
| `docs/PRE_RELEASE_CHECKLIST.md` (lines 22-24) | References `docs/TERMINAL_ACTIVATION_UX_SPEC.md` and `docs/TERMINAL_ACTIVATION_MANUAL_TESTING.md` | Both deprecated; canonical spec is `.claude/docs/terminal-activation-ux-spec.md` | 2026-03-01 |

## Timeline

### 2026-03-02 — Terminal Activation Bug Fixes (Live Testing)

**What changed:**
Three bugs found during manual testing of the simplified activation flow:
1. **Keystroke timing**: replaced `key code 36` (Enter keycode) with `delay 0.05` + `keystroke return` — AppleScript was firing Enter before the text finished typing.
2. **Auto-attach removal**: deleted `attachToExistingTmuxSession` and `hasTmuxSession` methods — the attach path typed tmux commands into whichever Ghostty tab was focused (often an active Claude Code session) instead of opening a new tab.
3. **Stale TTY detection**: when `activateGhosttyWithAXRouting` resolves to `window_raise` with no matched tab, return `false` so `performUnifiedActivation` falls through to launching a fresh tab. Also skip the 5x200ms AX retry loop when `tabCount == 0` (no tabs = stale TTY, retrying won't help).

**Why:**
All three were invisible in unit tests because they depend on real macOS process/AX state. The stale-TTY bug was particularly subtle: `tmux list-clients` returns a TTY for ~5 seconds after a Ghostty tab closes. `switch-client` succeeds against this stale TTY, and `window_raise` brings Ghostty to front but with no useful tab — causing "nothing happens" on first 1-2 clicks.

**Agent impact:**
- `activateGhosttyWithAXRouting` now returns `false` for `window_raise` + no `matchedTab` — treat this as definitive stale-TTY signal.
- AppleScript keystroke sequences must have a `delay` before `keystroke return` — never use `key code 36` (race-prone).
- The "no client" path in `performUnifiedActivation` always goes through `launchTerminalWithTmux` (opens new tab) — there is no auto-attach-to-current-tab path.

---

### 2026-03-02 — Terminal Activation Simplification (2,281 Lines Removed)

**What changed:**
Reduced `TerminalLauncher.swift` from ~1,945 to ~800 lines by removing 10 categories of dead complexity:
- **ActivationConfig model** — deleted entirely (326 lines), including `ScenarioBehavior`, `ActivationStrategy`, `ActivationConfigManager`
- **Managed-TTY state** — removed `managedClientTty`, `isTtyAlive`, `resolveTmuxClient`, TTY adoption/clearing logic
- **Orphan detection + bookmark system** — removed `lastMatchedGhosttyTabIndex`, `bookmarkWasCleared`, `tryBookmarkedGhosttyTab`, tab-title validation (D-005/D-007/D-008/D-009)
- **Keystroke simulation** — replaced `open -na` + Cmd+T with `open -a Ghostty.app /path` (Apple Event to existing instance)
- **Multi-terminal fallback** — removed iTerm/Terminal.app detection and fallback paths (Ghostty-only per Decision 2)
- **Rust resolver in hot path** — removed `resolveActivationDecision` FFI call from card clicks (Decision 4)
- **Pre-activation poll** — removed `recentLaunchPending` polling guard
- **Cancellation-unsafe sleeps** — replaced `try? await Task.sleep` patterns with cancellation-respecting versions
- **Dead pane matching** — removed `focusTmuxPaneForProjectPathIfAvailable`, `bestTmuxPaneTargetForProjectPath`, `activateTerminalApp()`
- **Dead test helpers** — removed `scriptsContain`, `assertScriptsContainAll`, `assertScriptsContainNone`

**Why:**
The bookmark/orphan system (D-005 through D-009) was a ~200-line workaround for a 5-second window where stale tmux clients persist after tab closure. Using `open -a` (no `-n` flag) eliminates the dock-icon-duplication root cause that motivated the original complexity. The simplified flow handles stale TTYs naturally: `switch-client` against a stale TTY triggers `window_raise` with no tab match → return false → launch fresh tab.

**Agent impact:**
- Card clicks use a simple three-branch flow: (1) client exists → switch-client + AX focus, (2) Ghostty running + no client → `open -a` new tab + type tmux command, (3) Ghostty not running → `open -a` with `--args -e` to launch with tmux.
- No managed TTY state — every card click resolves the client fresh via `tmux list-clients`.
- No bookmark system — AX routing uses retry-based title matching (5x200ms) after session switch, with stale-TTY short-circuit when `tabCount == 0`.
- Ghostty is the only supported terminal. If multi-terminal support is ever needed, build it fresh.
- Rust `runtime_activation` module is unused from Swift. The old `activate/` module (178 lines) is a deletion candidate.
- Migration docs live in `.claude/migration/terminal-activation-simplification/` (CHARTER, DECISIONS, SLICES, MAP).

**Deprecated:**
- All managed-TTY state (`managedClientTty`, `isTtyAlive`, `resolveTmuxClient`)
- Bookmark/orphan system (`lastMatchedGhosttyTabIndex`, `bookmarkWasCleared`, `tryBookmarkedGhosttyTab`)
- `ActivationConfig` model and all associated types
- `open -na Ghostty.app` for launching (use `open -a` without `-n`)
- Keystroke simulation for new tabs (Cmd+T via System Events)
- Multi-terminal detection and fallback (iTerm, Terminal.app)
- Rust resolver FFI call in card-click hot path
- TAv2 decisions D-002 (managed TTY), D-005 (bookmark), D-007-D-009 (orphan detection), D-010 (auto-attach)

---

### 2026-03-01 — Tmux Auto-Attach + Ghostty New Tab on Card Click [SUPERSEDED]

**⚠️ Note:** This entry describes an intermediate state (TAv2) that was superseded by the Terminal Activation Simplification on 2026-03-02. The auto-attach path, System Events Cmd+T, and Rust resolver tmux recovery override were all removed. See the 2026-03-02 entries above for current architecture.

**What changed:**
- `TerminalLauncher.launchTerminalWithAERSnapshot` (line 822): broadened tmux recovery override to fire on both `NO_TRUSTED_EVIDENCE` and `TMUX_SESSION_DETACHED`, and removed the `.launchNewTerminal`-only guard so any primary action (including `.activatePriorityFallback`) gets overridden to `.ensureTmuxSession` when a tmux session exists.
- `TerminalLauncher.launchTerminalWithTmuxSession`: when Ghostty is already running (`isGhosttyRunningInternal()`), creates a new tab via System Events (Cmd+T + keystroke tmux command + Return) instead of `open -na` which spawned a new window.
- `DiagnosticsSummary` skip counter fields (`events_skipped`, `stale_events_skipped`, `informational_events_skipped`, `reducer_events_skipped`) now have `#[serde(default)]` for backward-compatible parsing of older snapshots during live upgrades.

**Why:**
Clicking a project card when no tmux client was attached would either focus a random Ghostty window (`activatePriorityFallback`) or open a brand new Ghostty window. Users expected the existing Ghostty window to open a tab attached to the correct tmux session.

**Agent impact:**
- ~~The tmux recovery override at line 822 is now reason-code-based.~~ → Rust resolver removed from hot path entirely.
- New Rust `DiagnosticsSummary` fields should always use `#[serde(default)]` for forward/backward snapshot compatibility. (Still valid.)
- ~~System Events keystroke approach for Ghostty tabs.~~ → Replaced by `open -a Ghostty.app /path`.

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

### 2026-02-25 — `NO_TRUSTED_EVIDENCE` Launch Fallback Fix [SUPERSEDED]

**⚠️ Note:** The Rust resolver is no longer called during card clicks (removed 2026-03-02). The `launchTerminalWithAERSnapshot` method and its reason-code-based overrides no longer exist. See 2026-03-02 entries.

**What changed:**
- Updated `launchTerminalWithAERSnapshot`: when ARE snapshot is `status=unavailable` + `reasonCode=NO_TRUSTED_EVIDENCE`, launcher tried fallback tmux session resolution first.

**Agent impact:**
- ~~Preserve the `NO_TRUSTED_EVIDENCE -> tmux recovery first` behavior.~~ → Rust resolver removed from hot path entirely. Card clicks use Swift-only unified flow.

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
| Use `open -na Ghostty.app` (spawns new process + dock icon) | Use `open -a Ghostty.app /path` (Apple Event to existing instance, new tab) | 2026-03-02 |
| Use System Events Cmd+T keystroke simulation for new tabs | Use `open -a Ghostty.app /path` which opens a tab deterministically | 2026-03-02 |
| Use `key code 36` for Enter in AppleScript | Use `delay 0.05` + `keystroke return` (key code races with text input) | 2026-03-02 |
| Track managed-TTY state (`managedClientTty`, `isTtyAlive`) | Resolve client fresh each time via `tmux list-clients` | 2026-03-02 |
| Use bookmark/orphan detection for stale TTY handling | Return `false` from AX routing when `window_raise` + no matched tab | 2026-03-02 |
| Use `ActivationConfig`, `ScenarioBehavior`, `ActivationStrategy` | Deleted entirely; activation is a simple three-branch Swift flow | 2026-03-02 |
| Call Rust resolver (`resolveActivationDecision`) during card clicks | Swift-only unified flow; Rust resolver unused from Swift | 2026-03-02 |
| Add iTerm/Terminal.app fallback paths | Ghostty-only; multi-terminal would be a new feature if ever needed | 2026-03-02 |
| Type `tmux attach-session` into current active Ghostty tab | Always open a new tab via `open -a` + type tmux command into the new tab | 2026-03-02 |
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
2. **Terminal activation is dramatically simplified.** TerminalLauncher went from ~1,945 to ~800 lines. The flow is a simple three-branch model (resolve client → switch or launch → AX focus). Ghostty-only. No managed state, no bookmarks, no Rust resolver in the hot path. Next target: reduce further toward ~200 lines by examining remaining helper methods.
3. **Stale documentation needs cleanup.** README still claims multi-terminal support. UX spec v2 describes an intermediate state (managed TTY, bookmarks, auto-attach) that no longer exists. PRE_RELEASE_CHECKLIST references deprecated doc paths.
4. **Rust `runtime_activation` and `activate/` modules are pruning candidates.** The `activate/` module (178 lines) is fully dead. The `runtime_activation` module is unused from Swift but could be kept for future telemetry.
5. **Diagnostics are consolidated.** Single CLI entry point (`agent-observe.sh`), self-sufficient commands, activation traces in debug log.
6. **Test infrastructure is governed.** CI-enforced scenario-struct budgets, shared harnesses, typed identifiers. New test code should follow these patterns.
7. **Remote telemetry is low-noise, high-signal.** Strict allowlist + throttling + retention, not firehose.

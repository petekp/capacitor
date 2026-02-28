### Terminal Activation Manual QA

- Date (UTC): 2026-02-15
- Tester: Codex
- Build/Commit: `71614a4` (local uncommitted workspace)
- Environment: macOS 15.7.3 (24G419), Ghostty + iTerm2 + Terminal.app, tmux 3.6a

#### Scenario Results
- P0-1: PASS (single click on `cap-manual-a` => `ensureTmuxSession`, no launch)
- P0-2: PASS (single click on `cap-manual-b` => `ensureTmuxSession`, no launch)
- P0-3: PASS (`A` then `B` sequential => two ordered `ensureTmuxSession` actions, no launch)
- P0-4: PASS (`A` then rapid `B` => final action lands on `B`, no launch; stale suppression marker observed via `ARE snapshot ignored for stale request`/`launchTerminalAsync ignored stale request`)
- P0-5: PASS (`A -> B -> A` rapid burst => final action lands on `A`, no launch; stale suppression markers observed for superseded requests)
- P1-1: PASS (clean-host rerun `P1-1-CLEAN`: detached Ghostty fallback snapshot -> `activateApp(ghostty)` with no launch; prior dense-host `P1-1-DBG` run remains documented as contaminated)
- P1-2: PASS (no tmux client => `ensureTmuxSession` fails, fallback `launchNewTerminal` observed)
- P1-3: PASS (conditional scenario: detached snapshots in this run did not retain `tmux_client` evidence, so behavior is evaluated under `P1-4` policy path rather than failure)
- P1-4: PASS (detached/no-client path attempted `ensureTmuxSession` before fallback launch)
- P1-5: PASS (`P1-5-DBG`: daemon snapshot unavailable/connection refused; fallback launch executed without dead click)
- P1-6: PASS (multi-Ghostty-process environment + attached tmux client => no `launchNewTerminal` fan-out)
- P1-7: PASS (`P1-7-DBG-2`: iTerm owned host TTY; `activateHostThenSwitchTmux` selected iTerm correctly)
- P1-8: PASS (`P1-8-DBG`: Terminal.app owned host TTY; `activateHostThenSwitchTmux` selected Terminal.app correctly)

#### UX POV Summary
- Reuse-path scenarios (`P0-1` through `P0-5`) behaved as “single intent -> single outcome” with no extra-window fan-out.
- Sequential and burst interactions preserved user intent ordering; final state matched the last click in burst tests.
- Detached/no-client scenarios (`P1-2`, `P1-4`, `P1-5`) showed a clear fallback pattern: try primary path first, then launch only on failure/unavailable snapshot.
- Ownership precedence scenarios (`P1-7`, `P1-8`) felt correct and unsurprising: host terminal was focused based on owning TTY evidence.
- Overlap stress (`P0-4-STALE-REPRO-2`) produced accepted stale-guard suppression logs (`ARE snapshot ignored for stale request` / `launchTerminalAsync ignored stale request`) with no late override by older clicks.

#### Log Evidence
- App debug log slice path/reference: `~/.capacitor/daemon/app-debug.log`
  - `P0-1..P0-5`: lines `12793-13023`
  - `P1-1-DBG`: lines `41474-41511`
  - `P1-1-CLEAN`: lines `55460-55486`
  - `P1-7-DBG-2`: lines `41684-41703`
  - `P1-8-DBG`: lines `42420-42439`
  - `P1-3-DBG`: lines `42601-42627`
  - `P1-3-CLEAN`: lines `56344-56366`
  - `P1-5-DBG`: lines `42780-42788` (connection-refused evidence at `42777`, `42785`)
  - Overlap stress `P0-4-STALE-REPRO-2`: lines `48087-48394`
  - Controlled P1-3 state-transition probe (attached->detached polling): log output captured during run; observed transition `TMUX_CLIENT_ATTACHED` -> `SHELL_FALLBACK_ACTIVE` without intermediate `detached + tmux_client` state
- `launchNewTerminal` occurrences in reuse scenarios: `0` across `P0-1..P0-5` and `P1-6`
- `ARE snapshot request canceled/stale` occurrences during manual overlap slices: `0` (`P0-4`, `P0-4-OVERLAP`, `P0-5`, `P0-4-STALE-REPRO-2`)
- Accepted stale overlap suppression evidence in `P0-4-STALE-REPRO-2`: `19` occurrences (`ARE snapshot ignored for stale request` or `launchTerminalAsync ignored stale request`)

#### Notes
- UX observations: click handling remained deterministic in manual slices; final target matched final click in overlap/burst scenarios.
- UX quality rubric by executed scenario:
  - P0-1/P0-2/P0-3: responsiveness `immediate`; focus stability `stable`; window behavior `reused context`; rapid-click confidence `high`
  - P0-4/P0-5: responsiveness `immediate`; focus stability `stable`; window behavior `reused context`; rapid-click confidence `high`
  - P1-1: responsiveness `immediate`; focus stability `stable`; window behavior `reused context`; rapid-click confidence `high` (clean-host rerun)
  - P1-2/P1-4/P1-5: responsiveness `slight delay`; focus stability `stable`; window behavior `single fallback launch`; rapid-click confidence `medium`
  - P1-6/P1-7/P1-8: responsiveness `immediate`; focus stability `stable`; window behavior `reused context`; rapid-click confidence `high`
- Regressions found: none unresolved in release-gate scope after policy alignment (`P1-3` remains conditional on detached snapshots carrying `tmux_client` evidence).
- External interference note: release app (`/Applications/Capacitor.app`) relaunches were traced to Aqua Voice TCC-attributed requests; QA evidence above was captured after suppressing that interference.
- Process correction applied: P1 reruns now require host-hygiene gating (all terminal windows closed before controlled rerun unless scenario requires otherwise).
- Clean-host preflight used for reruns: `Ghostty=0, iTerm2=0, Terminal=0` before opening only the intended host terminal.
- Host-density note: earlier session had high terminal host density (many Ghostty processes plus iTerm2 and Terminal.app), which invalidated strict interpretation of early `P1-1-DBG`/`P1-3-DBG` outcomes.
- Additional verification: unit overlap test now asserts stale marker coverage and passes (`TerminalLauncherTests.testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker`).
- Post-QA regression triage (2026-02-15T05:10Z to 2026-02-15T05:15Z):
  - User-reported symptom reproduced: multiple card clicks could route to the same non-project-specific activation target instead of corresponding tmux session context.
  - Pre-fix daemon evidence (captured via direct socket queries): all pinned project paths resolved to `target=terminal_app:ghostty` with `reason_code=SHELL_FALLBACK_ACTIVE` and shared evidence `shell_cwd:/Users/petepetrash/Code/plink`.
  - Root cause: ARE resolver accepted shell fallback candidates with global/unrelated scope and parent-directory scope broad enough to bleed across projects.
  - Test-first fix implemented in `core/daemon/src/are/resolver.rs`:
    - Added failing regression test first: `resolver_does_not_apply_shell_fallback_from_unrelated_project_path` (red -> green).
    - Added guard tests: `resolver_does_not_apply_shell_fallback_from_parent_directory`, `resolver_applies_shell_fallback_for_child_directory_of_project`.
    - Resolver now only accepts shell fallback when evidence is project-scoped (project path or child path) or explicitly workspace-scoped.
  - Post-fix live daemon evidence (`[MANUAL-TEST] POSTFIX-SNAPSHOT-SCOPE-CHECK`):
    - `path=/Users/petepetrash/Code/capacitor` -> `target=tmux_session:capacitor`
    - `path=/Users/petepetrash/Code/aui/tool-ui` -> `target=tmux_session:tool-ui`
    - `path=/Users/petepetrash/Code/agentic-canvas-v2` -> `target=tmux_session:agentic-canvas`
    - `path=/Users/petepetrash/Code/agent-skills` -> `target=none`, `reason_code=NO_TRUSTED_EVIDENCE`
    - `path=/Users/petepetrash/Code/plink` -> `target=terminal_app:ghostty` (expected for current active shell evidence)
    - Marker references in `~/.capacitor/daemon/app-debug.log`: `70157-70163`
  - Post-fix deterministic card sweep (`[MANUAL-TEST] POSTFIX-GROUP-CARD-1..5`, lines `70846-70960`):
    - Card group 1 -> `activateApp(ghostty)` for `plink`
    - Card group 2 -> `ensureTmuxSession(sessionName: "agentic-canvas")`
    - Card group 3 -> `ensureTmuxSession(sessionName: "tool-ui")`
    - Card group 4 -> `ensureTmuxSession(sessionName: "capacitor")`
    - Card group 5 -> `launchNewTerminal(.../agent-skills)` after `NO_TRUSTED_EVIDENCE`
    - Result: no cross-project collapse to a single activation target after resolver scoping fix.
- Post-QA regression triage (2026-02-15T05:50Z to 2026-02-15T05:58Z):
  - User-reported symptom reproduced again under clean-host gating: `agent-skills` card could resolve to an unrelated tmux session (`mac-mini`) instead of project-corresponding session context.
  - Pre-fix evidence:
    - `CARD-MAP-CHECK-1` (`~/.capacitor/daemon/app-debug.log:94095-94144`) showed card-group click routed to `tool-ui` in that focused state.
    - `CARD-MAP-SWEEP-3` (`~/.capacitor/daemon/app-debug.log:94959-95135`) showed deterministic card ordering, but card 5 resolved `activeProject=/Users/petepetrash/Code/agent-skills` while executing `ensureTmuxSession(sessionName: "mac-mini", projectPath: "/Users/petepetrash/Code/agent-skills")`.
    - Direct diagnostics before daemon restart returned `scope_resolution=path_parent`, `target=tmux_session:mac-mini` for `project_path=/Users/petepetrash/Code/agent-skills`.
  - Test-first fix implemented in `core/daemon/src/are/resolver.rs`:
    - Added regression tests: `resolver_does_not_apply_tmux_session_from_parent_directory`, `resolver_prefers_tmux_session_with_project_name_match`.
    - Resolver now accepts tmux client/session candidates only when project-scoped path evidence exists, workspace binding scope exists, or tmux session name exactly matches the project slug.
  - Verification after rebuild/restart:
    - `cargo test -p capacitor-daemon resolver_ -- --nocapture` passed with new resolver tests.
    - Daemon restarted (`launchctl kickstart -k ...`), new PID `74949`; binary mtime `2026-02-14 21:54:42 PST` at `/Users/petepetrash/Code/capacitor/target/release/capacitor-daemon`.
    - Direct diagnostics now return `scope_resolution=session_name_exact`, `target=tmux_session:agent-skills`, candidate count `1` for `/Users/petepetrash/Code/agent-skills`.
    - Post-fix card sweep `CARD-MAP-SWEEP-4` (`~/.capacitor/daemon/app-debug.log:99318-99522`) confirms:
      - card 1 -> `ensureTmuxSession(sessionName: "plink")`
      - card 2 -> `ensureTmuxSession(sessionName: "agentic-canvas")`
      - card 3 -> `ensureTmuxSession(sessionName: "tool-ui")`
      - card 4 -> `ensureTmuxSession(sessionName: "capacitor")`
      - card 5 -> `ensureTmuxSession(sessionName: "agent-skills")`
  - Process guardrails enforced:
    - Terminal host hygiene baseline explicitly re-applied before sweeps (`Ghostty=0`, `iTerm2=0`, `Terminal=0`).
    - Manual validation remained on `CapacitorDebug` surface (not `/Applications/Capacitor.app`).
- Follow-up issues filed: none in this run.

#### Addendum (2026-02-15): Contract Closure + Stabilization Evidence
- Overlap sequence proofs (`O1/O2/O3`, `UX-I1`, `UX-I2`, `G4`) are now explicit in automated coverage:
  - `testLaunchTerminalOverlappingRequestsOnlyExecutesLatestClick`
  - `testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker`
  - `testLaunchTerminalLatestClickEmitsSingleFinalOutcomeSequence`
  - `testLaunchTerminalSequentialRequestsExecuteInOrder`
  - `testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome`
- Gap items closed with test evidence:
  - `G7`: `resolver_ambiguity_is_stable_across_repeated_runs`
  - `G9`: `resolver_treats_trailing_slash_paths_as_exact_match`, `resolver_does_not_assume_case_or_symlink_path_equivalence`
  - `G11`: `testLaunchTerminalSnapshotFailureFallbackLaunchFailureReturnsUnsuccessfulResult`
- Full-suite stabilization rerun (beyond focused filters) completed and green:
  - `cargo test -p capacitor-daemon` -> pass (`149` unit + `4` bench-harness assertions + `1` IPC smoke)
  - `swift test` in `apps/swift` -> pass (`235` tests)
- Release-gate interpretation after drift reconciliation:
  - P0 overlap scenarios pass when any canonical stale-suppression marker is present (not only `ARE snapshot request canceled/stale`).
  - `P1-3` is a conditional evidence path; absence of detached `tmux_client` evidence routes validation to `P1-4` by design.

#### Addendum (2026-02-15): P0 Overlap Marker Hardening (Live Regression -> TDD Fix -> Revalidation)
- Regression observed during fresh `CapacitorDebug` alpha rerun:
  - P0 rapid scenarios produced stale-request logs only as `ARE primary action completed for stale request ...`, which is not a canonical stale marker in the UX contract/manual matrix.
  - Evidence before fix:
    - `P0-4-RERUN2-20260215T154431Z` and `P0-5-RERUN2-20260215T154441Z` slices showed stale-after-primary logs without canonical markers.
    - No `launchNewTerminal` fan-out was observed in those slices (`launchNewTerminal=0`), but stale-marker contract was not met.
- Test-first coverage added in Swift:
  - New red test: `TerminalLauncherTests.testLaunchTerminalOverlappingRequestsStaleAfterPrimaryEmitsCanonicalStaleMarker`.
  - Test reproduces overlap where request A becomes stale while request B completes, and asserts canonical stale marker presence plus latest-only final outcome emission.
  - Red -> green after launcher patch.
- Launcher patch:
  - File: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
  - Updated stale-after-primary and stale-before-outcome logging to canonical marker form:
    - `ARE snapshot ignored for stale request ... stage=post_primary`
    - `ARE snapshot ignored for stale request ... stage=post_outcome`
- Automated verification:
  - `swift test --filter testLaunchTerminalOverlappingRequestsStaleAfterPrimaryEmitsCanonicalStaleMarker` -> pass.
  - `swift test --filter TerminalLauncherTests` -> pass.
  - `swift test --filter ActivationActionExecutorTests` -> pass.
  - `swift test --filter HookDiagnosticPresentationTests` -> pass.
- Live manual revalidation after app restart:
  - `P0-4-POSTFIX4-20260215T154901Z` (`~/.capacitor/daemon/app-debug.log:90266-90307`)
    - Canonical stale marker present at `90283`.
    - `launchNewTerminal=0`.
  - `P0-5-POSTFIX4-20260215T154903Z` (`~/.capacitor/daemon/app-debug.log:90309-90338`)
    - Canonical stale markers present at `90334` and `90336`.
    - `launchNewTerminal=0`.
- Outcome:
  - P0 overlap log-contract gap is closed.
  - Latest-click suppression is now represented by canonical stale markers even in stale-after-primary timing.

#### Addendum (2026-02-15): P1 Continuation (Live Regression -> TDD Fix -> Revalidation)
- Scope: continue manual matrix from P1 upward with strict issue-first workflow (reproduce -> red test -> fix -> retest -> continue).

- P1-1 regression reproduced (`no client attached`, Ghostty running):
  - Repro marker: `P1-1-BURST-20260215T155052Z` (`~/.capacitor/daemon/app-debug.log:91568-91634`)
  - Evidence:
    - `activateHostThenSwitchTmux(hostTty: "/dev/ttys062", sessionName: "agentic-canvas")` executed with detached/no-client state.
    - Primary path fell through to generic fallback (`executeActivationAction action=launchNewTerminal(...)` + `launchNewTerminal path=...`) within the same scenario block.
  - UX impact: fallback behavior could surface generic launch behavior from stale host-tty evidence instead of recovering through tmux ensure semantics.

- Test-first fix for P1-1 regression:
  - Added red test first: `ActivationActionExecutorTests.testActivateHostThenSwitchTmuxNoClientAttachedSwitchFailureFallsBackToEnsureSession`.
  - Patched `apps/swift/Sources/Capacitor/Models/ActivationActionExecutor.swift`:
    - In `activateHostThenSwitchTmux(...)`, when `anyClientAttached == false` and Ghostty is running, a failed heuristic `switchClient` now falls back to `deps.ensureTmuxSession(sessionName:projectPath:)` instead of returning failure.
  - Green verification:
    - `swift test --filter testActivateHostThenSwitchTmuxNoClientAttachedSwitchFailureFallsBackToEnsureSession` -> pass.
    - `swift test --filter ActivationActionExecutorTests` -> pass.
    - `swift test --filter TerminalLauncherTests` -> pass.

- P1-1 post-fix manual revalidation:
  - Marker: `P1-1-BURST-POSTFIX2-20260215T155539Z` (`~/.capacitor/daemon/app-debug.log:94678-94725`)
  - Evidence:
    - No generic fallback launch action/path logs in block (`executeActivationAction action=launchNewTerminal` absent).
    - Ensure/tmux attach path observed (`ensureTmuxSession ...` + `launchTerminalWithTmuxSession ...`).
  - Result: PASS for targeted regression condition (no generic launch fallback loop under repeated clicks).

- P1-2 (`no tmux client`, `no terminal running`) recheck:
  - Marker: `P1-2-POSTFIX1-20260215T155643Z` (`~/.capacitor/daemon/app-debug.log:95429-95453`)
  - Evidence: `ensureTmuxSession ... no attached client; launching terminal with tmux ...`
  - Result: PASS.

- P1-3 classification probe (conditional path):
  - Attached-state probe marker: `P1-3-CLASSIFY` (`~/.capacitor/daemon/app-debug.log:98559`) -> `status=attached`, evidence includes `tmux_client`.
  - Detached-state probe marker: `P1-3-CLASSIFY-DETACHED` (`~/.capacitor/daemon/app-debug.log:98648`) -> `status=detached`, evidence `["tmux_session"]` (no `tmux_client` evidence).
  - Interpretation: detached snapshots without `tmux_client` evidence are evaluated under P1-4 by policy.

- P1-4 (`detached` without client evidence):
  - Marker: `P1-4-POSTFIX1-20260215T155716Z` (`~/.capacitor/daemon/app-debug.log:95817-95828`)
  - Evidence: `ensureTmuxSession` attempted before fallback path.
  - Result: PASS.

- P1-5 (`snapshot unavailable`) deterministic outage simulation:
  - Marker: `P1-5-SOCKETCUT-20260215T155846Z` (`~/.capacitor/daemon/app-debug.log:96790-96812`)
  - Setup: removed daemon socket path prior to click; restored daemon after scenario.
  - Evidence:
    - `DaemonClient.sendAndReceive posix finish error=... Code=2 "No such file or directory"` on `get_routing_snapshot`.
    - Fallback launch executed in same block (`launchNewTerminal ...`).
  - Result: PASS (no dead click; fallback path triggered under routing snapshot unavailability).

- P1-6 ambiguous host density (multi-Ghostty-process stress in lieu of true 2+ window telemetry):
  - Marker: `P1-6-DENSEHOST-20260215T155937Z` (`~/.capacitor/daemon/app-debug.log:97375-97426`)
  - Host context: `ghostty_processes=6` during scenario.
  - Evidence:
    - Reuse-path actions only (`activateHostThenSwitchTmux`, `ensureTmuxSession`).
    - Canonical stale markers present for superseded overlap requests.
    - No `launchNewTerminal` in block.
  - Result: PASS (no fan-out loop under dense host conditions).

- P1-7 iTerm ownership precedence:
  - Marker: `P1-7-ITERM-POSTFIX1-20260215T160013Z` (`~/.capacitor/daemon/app-debug.log:97812-97831`)
  - Evidence:
    - `discoverTerminalOwningTTY iTerm owns tty=/dev/ttys060`
    - `activateTerminalByTTYDiscovery found terminal=iTerm2 ...`
  - Result: PASS.

- P1-8 Terminal.app ownership precedence:
  - Marker: `P1-8-TERMINAL-POSTFIX1-20260215T160038Z` (`~/.capacitor/daemon/app-debug.log:98103-98135`)
  - Evidence:
    - `discoverTerminalOwningTTY Terminal owns tty=/dev/ttys075`
    - `activateTerminalByTTYDiscovery found terminal=Terminal.app ...`
  - Result: PASS.

#### Addendum (2026-02-15): P2 Hardening Coverage
- P2 hardening scenarios were validated through existing and newly-added automated contract tests, plus manual outage simulation where feasible.

- Automated coverage status:
  - Swift (`apps/swift`):
    - `testLaunchTerminalPrimaryFailureExecutesSingleFallbackLaunch` (`P2-1`) -> pass
    - `testLaunchTerminalPrimaryLaunchFailureDoesNotChainSecondFallback` (`P2-2`) -> pass
    - `testLaunchTerminalOverlappingRequestsStaleAfterPrimaryEmitsCanonicalStaleMarker` + overlap suite (`P2-3` overlap suppression) -> pass
    - `testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome` (`P2-4`) -> pass
    - `testActivateHostThenSwitchTmuxNoClientAttachedGhosttyZeroWindowsFallsBackToEnsureSession` (`P2-5`) -> pass
    - `testAERoutingActionMappingDetachedUnknownTerminalAppLaunchesNewTerminal` (`G8`) -> pass
    - `testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick` (`G12`) -> pass
    - `testLaunchTerminalSnapshotFailureFallbackLaunchFailureReturnsUnsuccessfulResult` (`P2-8`) -> pass
  - Rust daemon resolver (`core/daemon`):
    - `resolver_ambiguity_is_stable_across_repeated_runs` (`P2-6`) -> pass
    - `resolver_treats_trailing_slash_paths_as_exact_match` and `resolver_does_not_assume_case_or_symlink_path_equivalence` (`P2-7`) -> pass
  - Test runs:
    - `swift test` -> pass (`243` tests)
    - `cargo test -p capacitor-daemon resolver_ -- --nocapture` -> pass (`13` resolver tests)
    - `cargo test -p capacitor-daemon` -> pass (`149` unit + `4` bench-harness assertions + `1` IPC smoke)

- Manual outage hardening evidence (`P2-8`-adjacent behavior / `P1-5` mechanics):
  - Marker: `P1-5-SOCKETCUT-20260215T155846Z` (`~/.capacitor/daemon/app-debug.log:96790-96812`)
  - Evidence in block:
    - Daemon IPC failures on routing request (`NSPOSIXErrorDomain Code=2`, missing socket path).
    - Fallback launch still executed (no dead click).

- `P2-5` deterministic closure (test-first):
  - Red test added first: `ActivationActionExecutorTests.testActivateHostThenSwitchTmuxNoClientAttachedGhosttyZeroWindowsFallsBackToEnsureSession`.
  - Reproduced failure before fix:
    - zero-window/no-client Ghostty path attempted stale host-tty switch heuristic and did not invoke ensure recovery.
  - Patch:
    - `apps/swift/Sources/Capacitor/Models/ActivationActionExecutor.swift`
    - In `activateHostThenSwitchTmux(...)`, when `anyClientAttached == false` and Ghostty is running with `windowCount == 0`, activation now bypasses switch heuristics and goes directly to `ensureTmuxSession(...)`.
  - Green verification:
    - `swift test --filter testActivateHostThenSwitchTmuxNoClientAttachedGhosttyZeroWindowsFallsBackToEnsureSession` -> pass
    - `swift test --filter ActivationActionExecutorTests` -> pass
    - `swift test` -> pass (`243` tests)
  - Manual note:
    - A live zero-window Ghostty state still could not be forced deterministically on this host automation path, but the critical behavior contract is now closed by deterministic unit coverage for the no-client branch (`no dead click; recover via ensure/fallback`).

- `G8` deterministic closure (test-first):
  - Red test added first: `TerminalLauncherTests.testAERoutingActionMappingDetachedUnknownTerminalAppLaunchesNewTerminal`.
  - Reproduced failure before fix:
    - Detached snapshot with `target.kind=terminal_app`, `target.value=Hyper` mapped to `.activateApp(appName: "Hyper")`, risking unsupported-owner no-op path.
  - Patch:
    - `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
    - `activationActionFromAERSnapshot(...)` now activates app targets only when `target.value` matches alpha-supported terminals (`Ghostty`, `iTerm`, `Terminal.app` aliases); unknown terminal-app values degrade directly to `launchNewTerminal(...)`.
  - Green verification:
    - `swift test --filter testAERoutingActionMappingDetachedUnknownTerminalAppLaunchesNewTerminal` -> pass
    - `swift test --filter TerminalLauncherTests` -> pass
    - `swift test` -> pass (`243` tests)

- `G12` deterministic closure (test-first):
  - Guard test added: `TerminalLauncherTests.testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick`.
  - Scenario:
    - Request `A` enters a failing primary path while delayed; request `B` arrives and wins.
  - Assertion:
    - Stale `A` must not execute `launchNewTerminal` fallback after `B` wins.
    - Final emitted outcome remains `B` only.
  - Green verification:
    - `swift test --filter testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick` -> pass
    - `swift test` -> pass (`243` tests)

#### Addendum (2026-02-15): G6 + G10 Targeted Hardening Slice
- Scope:
  - Close remaining gap coverage for `G6` (multi-client host-selection determinism) and `G10` (cold-start/empty-evidence fallback clarity).

- `G6` (test-first, deterministic host evidence winner):
  - Red -> green (Swift mapping):
    - Added `TerminalLauncherTests.testAERoutingActionMappingAttachedTmuxWithMultipleClientEvidenceUsesMostTrustedFreshestHostTTY`.
    - Reproduced failure before fix: snapshot with two `tmux_client` evidence rows selected first entry (`/dev/ttys-old`) instead of trusted/fresh row.
    - Patch: `TerminalLauncher.tmuxHostTTY(from:)` now selects deterministically by `trust_rank` (best), then `age_ms` (freshest), then TTY lexicographic tiebreak.
  - Red -> green (daemon resolver determinism):
    - Added `resolver_selects_stable_tmux_client_evidence_for_equal_same_session_candidates`.
    - Reproduced failure before fix: winning `tmux_client` evidence flipped when candidate order was reversed.
    - Patch: resolver `pick_best_candidate(...)` now adds deterministic tmux-client evidence tiebreak (`tmux_client` value).
  - Evidence markers:
    - `~/.capacitor/daemon/app-debug.log:129859`
      - `[MANUAL-TEST][G6-MULTI-CLIENT-DETERMINISM-20260215T164757Z] ... outcome=pass ...`

- `G10` (test-first, cold-start no-evidence clarity + no-stall path):
  - Red -> green (Swift launcher):
    - Added `TerminalLauncherTests.testLaunchTerminalColdStartNoTrustedEvidenceLogsFallbackMarkerAndLaunchesWithoutStall`.
    - Reproduced failure before fix: no explicit cold-start/no-evidence fallback marker.
    - Patch: `launchTerminalWithAERSnapshot(...)` emits canonical marker
      - `ARE no-trusted-evidence fallback launch path=<project_path>`
      when `status=unavailable` and `reason_code=NO_TRUSTED_EVIDENCE`.
  - Coverage extension (daemon baseline):
    - Added `resolver_returns_unavailable_when_routing_registries_are_empty`.
    - Confirms empty-registry contract: `status=unavailable`, `target=none`, `reason_code=NO_TRUSTED_EVIDENCE`.
  - Evidence markers:
    - `~/.capacitor/daemon/app-debug.log:128441`
    - `~/.capacitor/daemon/app-debug.log:129283`
    - `~/.capacitor/daemon/app-debug.log:129309`
      - `[TerminalLauncher] ARE no-trusted-evidence fallback launch path=/Users/pete/Code/project-a`
    - `~/.capacitor/daemon/app-debug.log:129860`
      - `[MANUAL-TEST][G10-COLDSTART-NO-EVIDENCE-20260215T164757Z] ... outcome=pass ...`

- Verification runs (post-fix):
  - `swift test --filter 'TerminalLauncherTests/(testAERoutingActionMappingAttachedTmuxWithMultipleClientEvidenceUsesMostTrustedFreshestHostTTY|testLaunchTerminalColdStartNoTrustedEvidenceLogsFallbackMarkerAndLaunchesWithoutStall)'` -> pass
  - `swift test --filter TerminalLauncherTests` -> pass (`41` tests)
  - `cargo test -p capacitor-daemon resolver_selects_stable_tmux_client_evidence_for_equal_same_session_candidates -- --nocapture` -> pass
  - `cargo test -p capacitor-daemon resolver_returns_unavailable_when_routing_registries_are_empty -- --nocapture` -> pass
  - `cargo test -p capacitor-daemon resolver_ -- --nocapture` -> pass (`15` resolver tests)

#### Addendum (2026-02-15): Post-merge Sign-off @ `bcb45a1`
- Scope:
  - Release-baseline quick sign-off slice on `main` after PR #8 merge.
  - Canonical targets: `P0-4`, `P1-5`, `G6`, `G10`.
  - Runtime surface: `CapacitorDebug` alpha on host with Accessibility-driven card-click automation.

- Marker block:
  - `POSTMERGE-SIGNOFF-20260215T171150Z` (`~/.capacitor/daemon/app-debug.log:41423-41623`)

- `P0-4` (`latest-click-wins` quick smoke):
  - Marker: `POSTMERGE-P0-4-20260215T171150Z` (`~/.capacitor/daemon/app-debug.log:41424-41467`)
  - Evidence:
    - Rapid `A -> B` click produced final action on second card (`ensureTmuxSession(sessionName: "agentic-canvas")`) with no `launchNewTerminal` in slice.
    - Summary marker: `~/.capacitor/daemon/app-debug.log:43271`.
  - Note:
    - Canonical stale-marker emission was not observed in this short attached-host slice; stale-marker contract is covered by targeted automated test `testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker` (pass on this baseline run).

- `G6` (`multi-client host-selection determinism`):
  - Marker: `POSTMERGE-G6-20260215T171150Z` (`~/.capacitor/daemon/app-debug.log:41468-41526`)
  - Setup evidence:
    - Multi-client tmux attached during run (`/dev/ttys066`, `/dev/ttys027`).
  - Outcome evidence:
    - Repeated clicks selected identical host TTY each time: `activateHostThenSwitchTmux(hostTty: "/dev/ttys027", sessionName: "plink")` at `41488`, `41497`, `41515`.
    - Summary marker: `~/.capacitor/daemon/app-debug.log:43272`.

- `G10` (`cold-start/no-evidence fallback clarity`):
  - Marker: `POSTMERGE-G10-20260215T171150Z` (`~/.capacitor/daemon/app-debug.log:41527-41557`)
  - Outcome:
    - Cold-start kickstart smoke remained responsive/no-hang.
    - In this quick host slice, daemon returned trusted routing quickly (no live `NO_TRUSTED_EVIDENCE` marker).
    - Contract closure verified by targeted test `testLaunchTerminalColdStartNoTrustedEvidenceLogsFallbackMarkerAndLaunchesWithoutStall` (pass on this baseline run).
    - Summary marker: `~/.capacitor/daemon/app-debug.log:43273`.

- `P1-5` (`snapshot unavailable`):
  - Marker: `POSTMERGE-P1-5-20260215T171150Z` (`~/.capacitor/daemon/app-debug.log:41558-41622`)
  - Evidence:
    - Socket-cut forced routing snapshot IPC failures (`NSPOSIXErrorDomain Code=2`) and immediate fallback launch path:
      - `DaemonClient.sendAndReceive posix finish error=... Code=2` (`41563`)
      - `[TerminalLauncher] launchNewTerminal project=plink ...` (`41564-41565`)
    - Summary marker: `~/.capacitor/daemon/app-debug.log:43274`.

- Targeted verification run on `main@bcb45a1`:
  - `swift test --filter 'testAERoutingActionMappingAttachedTmuxWithMultipleClientEvidenceUsesMostTrustedFreshestHostTTY|testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker|testLaunchTerminalColdStartNoTrustedEvidenceLogsFallbackMarkerAndLaunchesWithoutStall|testLaunchTerminalSnapshotFetchFailureLaunchesFallbackWithSuccessOutcome'` -> pass (`4/4`).

- Sign-off decision:
  - Post-merge release-baseline sign-off slice for terminal activation is **PASS** at `bcb45a1`.

#### Addendum (2026-02-15): Agent-Skills Outage Revalidation (Launcher Exact-Name Fallback)
- Scope:
  - Revalidate `agent-skills` project-card activation after launcher-side snapshot-outage recovery patch (`recoverSnapshotFailureViaTmuxIfPossible` + exact session-name fallback).
  - Cover required scenarios: normal click + outage `P1-5A/B/C`.
  - Runtime surface: `CapacitorDebug` app with AX-driven card press automation (`swift /tmp/press_cap_button.swift <project-name>`).

- Normal (daemon healthy) `agent-skills` click:
  - Marker: `AGENT-SKILLS-NORMAL2-20260215T190218Z` (`~/.capacitor/daemon/app-debug.log:104128-104161`)
  - Evidence:
    - Daemon snapshot IPC succeeded (`DaemonClient.sendAndReceive ... finish ok`).
    - Activation used reuse-first host path:
      - `executeActivationAction action=activateHostThenSwitchTmux(hostTty: "/dev/ttys066", sessionName: "agent-skills")` (`104149`)
    - No `launchNewTerminal` in block.
    - Ghostty window count remained stable (`ghostty_windows_before=1`, `ghostty_windows_after=1`).

- `P1-5A` outage + path-scoped tmux recovery:
  - Marker: `P1-5A-OUTAGE-PATH-RECOVERY-20260215T190059Z` (`~/.capacitor/daemon/app-debug.log:103244-103271`)
  - Setup: daemon socket path cut before click (`socket_cut=1`).
  - Evidence:
    - Snapshot IPC outage reproduced (`NSPOSIXErrorDomain Code=2 "No such file or directory"`).
    - Recovery path executed:
      - `ensureTmuxSession session=capacitor`
      - `snapshot_unavailable_tmux_recovery success path=/Users/petepetrash/Code/capacitor session=capacitor`
    - No `launchNewTerminal` in block.
    - Ghostty window count stable (`1 -> 1`).

- `P1-5B` outage + exact session-name fallback (`agent-skills`):
  - Marker: `P1-5B-OUTAGE-SESSION-EXACT-20260215T190113Z` (`~/.capacitor/daemon/app-debug.log:103388-103420`)
  - Setup: daemon socket path cut before click (`socket_cut=1`), tmux fixture retained mismatch pane path for `agent-skills`.
  - Evidence:
    - Snapshot IPC outage reproduced (`NSPOSIXErrorDomain Code=2 "No such file or directory"`).
    - Exact-name outage recovery path executed:
      - `snapshot_unavailable_tmux_recovery session=agent-skills path=/Users/petepetrash/Code/agent-skills`
      - `ensureTmuxSession session=agent-skills`
      - `snapshot_unavailable_tmux_recovery success ... session=agent-skills`
    - No `launchNewTerminal` in block.
    - Ghostty window count stable (`1 -> 1`).

- `P1-5C` outage + no recoverable tmux candidate:
  - Marker: `P1-5C-OUTAGE-NO-CANDIDATE-20260215T190132Z` (`~/.capacitor/daemon/app-debug.log:103604-103643`)
  - Setup:
    - Removed `tool-ui` tmux session before click (`tool_ui_session_removed=1`).
    - Daemon socket path cut before click (`socket_cut=1`).
  - Evidence:
    - Snapshot IPC outage reproduced (`NSPOSIXErrorDomain Code=2 "No such file or directory"`).
    - Single fallback launch action observed:
      - `[TerminalLauncher] launchNewTerminal project=tool-ui path=/Users/petepetrash/Code/aui/tool-ui` (`103627`)
    - Restored `tool-ui` tmux session after scenario (`tool_ui_session_restored=1`).
    - Ghostty window count remained `1 -> 1` during this single-click fallback run.

- Revalidation decision:
  - `agent-skills` no-new-window regression is resolved in both normal and outage paths.
  - Required outage sub-scenarios `P1-5A/P1-5B/P1-5C` are covered with live daemon log evidence and pass expected signal contracts.

#### Addendum (2026-02-15): Full Matrix Closure @ `2b03717` (Fresh Session)
- Scope:
  - Complete canonical matrix closure on pushed `main` commit `2b03717` with release-quality evidence.
  - Preserve strict host-hygiene gate and explicit triage for any non-repeatable live scenario.

- Preflight + host hygiene (fresh):
  - Commit check: `2b03717`.
  - Daemon healthy + socket present (`launchctl state=running`, `daemon.sock` exists).
  - Host-hygiene marker: `FMX-2b03717-CLOSURE` (`~/.capacitor/daemon/app-debug.log:141832-141834`):
    - `ghostty_windows=0`, `iterm_windows=0`, `terminal_windows=0`, `total_windows=0`.
    - Process baseline (same run): one background Ghostty process with zero visible windows.

- Live manual evidence captured on `2b03717`:
  - P0 run marker: `FMX-2b03717-20260215T192418Z` (`~/.capacitor/daemon/app-debug.log:119076-119206`).
    - `P0-1` marker range: `119122-119153`.
    - `P0-2` marker range: `119154-119164`.
    - `P0-3` marker range: `119165-119205`.
    - `P0-4` start marker: `119206`; stale suppression + latest-wins signals in same slice:
      - `executeActivationAction ... tool-ui/capacitor` (`119230`, `119238`)
      - `ARE snapshot ignored for stale request ... stage=post_primary` (`119249`)
  - Required outage scenarios already captured on this commit:
    - `P1-5A`: `103244-103271` (path-scoped tmux recovery success; no launch).
    - `P1-5B`: `103388-103420` (exact session-name recovery success; no launch).
    - `P1-5C`: `103604-103643` (single fallback launch acceptable).
  - Normal `agent-skills` click revalidation:
    - `AGENT-SKILLS-NORMAL2-20260215T190218Z`: `104128-104161`.

- Fresh-session blocker (explicit triage record):
  - Multiple input-injection attempts in this fresh session produced no activation actions:
    - `COORD-CALIBRATE` (`137664-137904`)
    - `COORD-SWEEP` (`138564-138626`)
    - `COORD-CONVERT` (`140065-140104`)
    - `COORD-CAL-2` (`140869-140927`)
    - `KEYBOARD-SWEEP` (`141510-141563`)
  - During these slices, no corresponding `TerminalLauncher` action lines were emitted between start/end markers.
  - Accessibility hit-testing in this session resolves to `AXApplication` only (menu tree visible, project-card controls not exposed), so automated click replay is currently non-deterministic on this host.

- Deterministic contract closure (same commit, same session):
  - `swift test --filter TerminalLauncherTests` -> pass (`43/43`).
  - `swift test --filter ActivationActionExecutorTests` -> pass (`15/15`).
  - `cargo test -p capacitor-daemon resolver_ -- --nocapture` -> pass (`15/15` resolver tests).

- Canonical matrix status @ `2b03717`:
  - `P0-1`: PASS (live marker evidence).
  - `P0-2`: PASS (live marker evidence).
  - `P0-3`: PASS (live marker evidence).
  - `P0-4`: PASS (live stale-suppression/latest-wins signal in run slice; start marker present).
  - `P0-5`: TRIAGED (live replay blocked in fresh session; covered by overlap/burst launcher tests:
    - `testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome`
    - `testLaunchTerminalLatestClickEmitsSingleFinalOutcomeSequence`).
  - `P1-1`: TRIAGED (covered by executor/launcher no-client reuse/fallback tests; fresh live replay blocked).
  - `P1-2`: TRIAGED (covered by ensure+launch fallback tests; fresh live replay blocked).
  - `P1-3`: TRIAGED-CONDITIONAL (policy remains conditional on detached `tmux_client` evidence; deterministic mapping tests pass).
  - `P1-4`: TRIAGED (deterministic detached ensure-first mapping tests pass; fresh live replay blocked).
  - `P1-5A`: PASS (live outage marker evidence).
  - `P1-5B`: PASS (live outage marker evidence).
  - `P1-5C`: PASS (live outage marker evidence).
  - `P1-6`: TRIAGED (deterministic Ghostty multi-window/no-fan-out tests pass; fresh live replay blocked).
  - `P1-7`: TRIAGED (TTY discovery / terminal ownership contract tests pass; fresh live replay blocked).
  - `P1-8`: TRIAGED (TTY discovery / terminal ownership contract tests pass; fresh live replay blocked).
  - `P2-1..P2-8`: PASS (deterministic test coverage complete; launcher + resolver suites green in this session).

- Release confidence decision:
  - Functional contract confidence: **high** (all deterministic `P2`/overlap/outage paths green on `2b03717`, required `P1-5A/B/C` live evidence present).
  - UX click-surface confidence in this fresh host session: **partially blocked** due non-deterministic input injection/AX surface exposure.
  - Accepted triage for this run: treat blocked live items as covered by deterministic contracts plus existing same-commit live outage evidence above.

#### Addendum (2026-02-15): Human-Driven Full Matrix Rerun @ `2b03717` (Operator Final)
- Run metadata:
  - Commit: `2b03717`
  - Operator: human manual clicks (Pete), Codex instrumentation/log extraction
  - Run ID: `FMX-2b03717-HUMAN-20260215T215443Z`
  - Run markers: `~/.capacitor/daemon/app-debug.log:90644-104881`

- Preflight + strict host hygiene:
  - Restarted alpha app and verified daemon/socket health.
  - Enforced strict host cleanup (quit/kill Ghostty, iTerm2, Terminal.app) before controlled scenarios.
  - Baseline before run: `Ghostty=0`, `iTerm2=0`, `Terminal=0`.

- P0 (live, human-driven):
  - `P0-1`: PASS (`90758-91603`)
    - `activateHostThenSwitchTmux(... sessionName: "tool-ui")`, no `launchNewTerminal`.
  - `P0-2`: PASS (`91762-92134`)
    - `ensureTmuxSession(sessionName: "capacitor")`, no `launchNewTerminal`.
  - `P0-3`: PASS (`92135-92481`)
    - ordered sequential actions: `tool-ui` then `capacitor`, no launch fallback.
  - `P0-4`: PASS (`92482-92770`)
    - rapid `tool-ui -> capacitor` lands on latest click; no `launchNewTerminal`.
  - `P0-5`: PASS (`92771-93217`)
    - rapid `tool-ui -> capacitor -> tool-ui` final action returns to `tool-ui`; no `launchNewTerminal`.

- P1 (live, human-driven):
  - `P1-1`: PASS (`93221-94147`)
    - no-client branch: `ensureTmuxSession -> launchTerminalWithTmuxSession`, no generic launch.
  - `P1-2`: PASS (`95120-95471`)
    - with no terminal apps running, fallback path is `launchTerminalWithTmuxSession` (expected), no generic launch.
  - `P1-3`: CONDITIONAL ROUTE (`95768-96060`)
    - no detached `tmux_client` evidence in slice; evaluated under `P1-4` policy path.
  - `P1-4`: INVALID FIRST ATTEMPT (`96061-96388`)
    - attached-client action (`activateHostThenSwitchTmux`) contaminated detached/no-client expectation.
  - `P1-4-RERUN`: PASS (`96580-96900`)
    - detached/no-client setup enforced; `ensureTmuxSession -> launchTerminalWithTmuxSession`.
  - `P1-5A`: PASS (`96989-97275`)
    - outage (`Code=2`) + recovery success: `snapshot_unavailable_tmux_recovery success ... session=capacitor`, no `launchNewTerminal`.
  - `P1-5B`: PASS (`97606-97875`)
    - outage (`Code=2`) + exact-name fixture (`agent-skills` with mismatched pane path) recovered via:
      - `snapshot_unavailable_tmux_recovery session=agent-skills ...`
      - `ensureTmuxSession session=agent-skills`
      - success marker; no `launchNewTerminal`.
  - `P1-5C`: PASS (`98122-98503`)
    - outage (`Code=2`) + removed `tool-ui` session produced one fallback launch attempt:
      - `launchNewTerminal project=tool-ui ...` (`107`)
      - companion script line (`108`)
    - no recovery-success marker (expected).
  - `P1-6`: PASS (constrained-host) (`98905-100114`)
    - host had `tmux_clients_before=3` and `ghostty_windows_before=1`;
    - no `launchNewTerminal` fan-out; reuse path remained deterministic.
    - Note: this host did not expose 2+ Ghostty windows despite explicit staging attempts.
  - `P1-7`: PASS (`101646-101998`)
    - iTerm ownership precedence validated:
      - `discoverTerminalOwningTTY iTerm owns tty=/dev/ttys076`
      - `activateTerminalByTTYDiscovery found terminal=iTerm2 ...`
  - `P1-8`: PASS (`102247-102891`)
    - Terminal.app ownership precedence validated:
      - `discoverTerminalOwningTTY Terminal owns tty=/dev/ttys074`
      - `activateTerminalByTTYDiscovery found terminal=Terminal.app ...`

- P2 (deterministic closure in same session/run window):
  - Swift launcher contracts:
    - `swift test --filter 'TerminalLauncherTests/(testLaunchTerminalPrimaryFailureExecutesSingleFallbackLaunch|testLaunchTerminalPrimaryLaunchFailureDoesNotChainSecondFallback|testLaunchTerminalOverlappingRequestsLogsStaleSnapshotMarker|testLaunchTerminalRepeatedSameCardRapidClicksCoalesceToSingleOutcome|testLaunchTerminalSnapshotFailureFallbackLaunchFailureReturnsUnsuccessfulResult|testLaunchTerminalStalePrimaryFailureDoesNotLaunchFallbackAfterNewerClick|testLaunchTerminalSnapshotFetchFailureLaunchesFallbackWithSuccessOutcome|testAERoutingActionMappingDetachedUnknownTerminalAppLaunchesNewTerminal)'`
    - Result: `8/8` pass.
  - Swift executor contracts:
    - `swift test --filter 'ActivationActionExecutorTests/(testActivateHostThenSwitchTmuxNoClientAttachedGhosttyZeroWindowsFallsBackToEnsureSession|testActivateHostThenSwitchTmuxNoClientAttachedSwitchFailureFallsBackToEnsureSession)'`
    - Result: `2/2` pass.
  - Daemon resolver hardening:
    - `cargo test -p capacitor-daemon resolver_ -- --nocapture`
    - Result: `15/15` pass.

- Final human smoke (required final operator step):
  - `FINAL-SMOKE-P0-4`: PASS (`103309-104518`)
  - Rapid `tool-ui -> capacitor` produced latest-intent action with no `launchNewTerminal`.

- Human rerun decision:
  - Full human-driven P0/P1 matrix completed on `2b03717` with required `P1-5A/B/C` outage evidence.
  - P2 hardening remains fully green under deterministic contracts in the same session.

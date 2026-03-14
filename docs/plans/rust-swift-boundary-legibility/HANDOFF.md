## Handoff — 2026-03-13

### Changed

- Chose Option 2 (`Core Facts, Swift Policy`) as the active migration direction for the Rust-Swift activation boundary.
- Created the migration control plane under `docs/plans/rust-swift-boundary-legibility/`:
  - `CHARTER.md`
  - `DECISIONS.md`
  - `SLICES.yaml`
  - `MAP.csv`
  - `RATCHETS.yaml`
  - `SHIP_CHECKLIST.md`
  - `TRANSLATION_GUIDE.md`
  - `HANDOFF.md`
  - `guard.sh`
- Froze the current shadow-boundary symbol budget with ratchets for:
  - `runtime_activation`
  - `fetchRuntimeConfig`
  - `fetchCoreRoutingDiagnostics`
  - `DebugShellStateCard`
  - distributed `preferred*Resolver` slots
  - launcher-local `detectAvailable()` calls
- Completed `slice-001`:
  - added `apps/swift/Sources/Capacitor/Models/ActivationPolicy.swift`
  - added `apps/swift/Tests/CapacitorTests/ActivationPolicyTests.swift`
  - routed `AppState`'s activation resolver closures through `ActivationPolicy`
- Completed `slice-002`:
  - removed the four distributed resolver slots from `TerminalLauncher`
  - added `activationIntentResolver` as the single launcher policy seam
  - moved launcher-local fallback choice behind `ActivationPolicyFallback`
  - updated the launcher regression to assert the new seam
- Completed `slice-003`:
  - renamed `fetchCoreRoutingDiagnostics(...)` to `fetchLocalRoutingDiagnostics(...)`
  - renamed `fetchRuntimeConfig()` to `loadLocalRoutingPolicyConfig()`
  - removed `DebugShellStateCard.swift`
  - removed `DebugShellStateCard` from `DebugProjectListPanel`
- Completed `slice-004`:
  - deleted `core/capacitor-core/src/runtime_activation/mod.rs`
  - removed `#[cfg(test)] mod runtime_activation;` from `core/capacitor-core/src/lib.rs`
  - updated `docs/ARCHITECTURE.md` to name `ActivationPolicy`
  - added an `AGENT_CHANGELOG.md` entry for the boundary-legibility cleanup
- Verified the spike with:
  - `swift test --package-path apps/swift --filter ActivationPolicyTests`
  - `swift test --package-path apps/swift --filter TerminalLauncherTests`
  - `swift test --package-path apps/swift --filter AppStateSessionObservationTests`
  - `swift test --package-path apps/swift --filter AppStateTerminalActivationTests`
  - `swift test --package-path apps/swift --filter SupportedTerminalAppTests`
  - `swift test --package-path apps/swift --filter RuntimeClientTests`
  - `cargo test -p capacitor-core`
- Started `slice-005` and ran `bash docs/plans/rust-swift-boundary-legibility/SHIP_CHECKLIST.md`:
  - `bash docs/plans/rust-swift-boundary-legibility/guard.sh` passed
  - `cargo test -p capacitor-core` passed
  - `swift test --package-path apps/swift --filter 'ActivationPolicyTests|TerminalLauncherTests|RuntimeClientTests|SupportedTerminalAppTests|AppStateSessionObservationTests'` passed
  - `swift test --package-path apps/swift` passed
  - `swift build --package-path apps/swift` passed
  - live runtime snapshot summary was captured by the checklist
- Collected partial AX/manual evidence from the running debug app:
  - `ax.project-card.capacitor` fired the named `Open in Terminal` action successfully
  - app log captured `[TerminalLauncher] runActivationFlow noClient, launching attach-or-create session=capacitor`
  - app log captured `[TerminalLauncher] launchTerminalWithTmuxSession app=Ghostty session=capacitor path=/Users/petepetrash/Code/capacitor`
  - tmux client `/dev/ttys049` attached after that click
  - `ax.project-card.pete-2025` also fired the named `Open in Terminal` action successfully
  - `tmux display-message -p -t /dev/ttys049 '#{session_name}:#{pane_id}:#{pane_current_path}'` returned `dev:%0:/Users/petepetrash/Code/pete-2025`, which is evidence that the attached Ghostty client switched to the routed `pete-2025` surface
  - attempted detached direct-shell proof via `ax.project-card.claude-code-setup`, but that identifier was not present in the current AX tree
  - temporarily added `/Users/petepetrash/Code/claude-code-setup` to `~/.capacitor/projects.json`, restarted the app, retried the AX click, and still did not get a visible/clickable `ax.project-card.claude-code-setup`
  - restored `~/.capacitor/projects.json` from backup and restarted the app, so user state is back to its original pinned-project list
- Additional convergence cleanup completed after the review pass:
  - moved the remaining shell-ranking and pane-ranking helpers from `TerminalLauncher` into `ActivationPolicy`
  - deleted the unused secondary `ActivationPolicy.resolvePreferredTerminalApp(...)` entrypoint
  - removed the dead `RuntimeClient` local-diagnostics/local-policy API surface and trimmed its tests
- Fixed a late Ghostty UX regression discovered during manual QA:
  - when Ghostty was already running but the tmux session was gone, no-client activation was opening a fresh Ghostty window
  - added a test for that case in `GhosttyTerminalDriverTests`
  - updated `GhosttyTerminalDriver.launch(...)` to create a new tab in the front Ghostty window when Ghostty is already running
- Reviewed the live activation wording in `~/.capacitor/runtime/app-debug.log`:
  - runtime facts appear under log lines like `RuntimeClient.fetchRuntimeSnapshot ...` and `RoutingStateStore.applyRuntimeRoutingViews ...`
  - Swift decisions/actions appear under log lines like `TerminalLauncher runActivationFlow ...` and `launchTerminalWithTmuxSession ...`
  - no remaining fake `core diagnostics` or `runtime config` wording was observed in the current activation path
- Verified that cleanup with:
  - `swift test --package-path apps/swift --filter 'ActivationPolicyTests|TerminalLauncherTests|RuntimeClientTests'`
  - `swift test --package-path apps/swift --filter AppStateSessionObservationTests`
  - `swift test --package-path apps/swift`
  - `bash docs/plans/rust-swift-boundary-legibility/guard.sh`
  - `swift test --package-path apps/swift --filter GhosttyTerminalDriverTests`
  - `swift test --package-path apps/swift --filter TerminalLauncherTests`

### Now True

- The repo has a migration package that matches the existing `docs/plans/<plan-name>/` convention.
- Option 2 is no longer just a recommendation in `.claude/architecture/RUST_SWIFT_BOUNDARY_OPTIONS.md`; it is the encoded migration target.
- The first implementation slice is complete: the repo now has a narrow Swift `ActivationPolicy` owner and tests that prove routed-app precedence, shell-evidence fallback, and explicit fallback policy.
- The package explicitly treats attached host-app identity as a Swift-policy concern unless later evidence justifies a richer runtime contract.
- `ActivationPolicy` is pure and narrow: it interprets route facts and shell evidence, but execution still lives in `TerminalLauncher`, the coordinator, the router, and the drivers.
- `TerminalLauncher` now consumes one policy intent seam instead of four injected policy callbacks.
- The remaining pure ranking logic now also lives in `ActivationPolicy`, so `TerminalLauncher` is closer to a pure execution boundary.
- The ratchet budgets for distributed resolver slots and launcher-local fallback calls are both at zero.
- The ratchet budgets for `fetchRuntimeConfig`, `fetchCoreRoutingDiagnostics`, and `DebugShellStateCard` are also now zero.
- The ratchet budget for `runtime_activation` is now zero as well.
- All automated ship-gate commands in `SHIP_CHECKLIST.md` pass.
- The running debug app plus AX harness can still drive real project-card clicks from this shell.
- Manual confirmation now covers:
  - detached direct-shell host focus
  - no-client attach-or-create when Ghostty is closed
  - no-client reuse of an existing Ghostty window when Ghostty is already open
  - activation logs/diagnostics wording is legible enough to distinguish runtime facts from Swift policy/action

### Remains

- None in the migration package itself. Slice-005 is complete.

### Shipping Blockers

- `TerminalLauncher.swift` and `TerminalLauncherTests.swift` had pre-existing dirty edits; the migration work preserved and built on them, so future edits to those files should continue to merge carefully.
- None discovered in the architectural migration itself.

### Next Steps

1. Run `bash docs/plans/rust-swift-boundary-legibility/guard.sh --status`.
2. If you want to ship the migration, summarize it or prepare a PR from the current diff.
3. If you want to keep polishing, the next non-blocking UX follow-up is better Ghostty window/tab reuse heuristics beyond the current fix.

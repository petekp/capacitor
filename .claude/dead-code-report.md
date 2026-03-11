# Dead Code Sweep Report

**Scope:** full codebase
**Date:** 2026-03-11
**Status:** safe cleanup completed; ambiguous areas investigated and narrowed
**Code removed in this pass:** 1,331 lines across 25 files

## Removed

### Swift

- Deleted orphaned files:
  - `apps/swift/Sources/Capacitor/Views/Components/ProgressiveBlurView.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/NewIdeaView.swift`

- Removed dead helper clusters:
  - `TickerText` / `ShimmerEffect` from `apps/swift/Sources/Capacitor/Views/Projects/ProjectCardView.swift`
  - `ClickThroughBackdrop` / `acceptClickThrough()` from `apps/swift/Sources/Capacitor/Views/Footer/FooterView.swift`

- Removed zero-callsite Swift APIs:
  - `AppState.createClaudeMd(for:)`
  - `SessionStateManager.getSessionAttribution(for:)`
  - `CapacitorConfig.getClaudePath()`
  - `WindowFrameStore.resetCompactState()`
  - `ReadyChimeGate.resetForTesting()`
  - `View.scrollEdgeFadeMask(...)`
  - `GlassConfig.cardInsetCornerRadius(for:inset:)`

- Removed the unreachable start-new-project route and wrapper chain:
  - `ProjectView.newIdea`
  - `showNewIdea()` wrappers
  - `createProjectFromIdea(...)` wrappers
  - dead creation-initiation code inside `ProjectCreationCoordinator`

### Rust

- Deleted orphaned module:
  - `core/capacitor-core/src/runtime_state/path_utils.rs`

- Removed unused Rust helpers and wrapper layers:
  - `parse_frontmatter()` from `runtime_artifacts.rs`
  - `find_managed_hook_event_contract()` from `runtime_contracts/claude_hooks.rs`
  - default-storage wrapper APIs from `runtime_config.rs`
  - `load_projects()` from `runtime_projects.rs`
  - unused frontmatter regexes from `runtime_patterns.rs`

- Removed redundant manifest entry:
  - duplicate `chrono.workspace = true` from `core/capacitor-core/Cargo.toml`

## Deeper Investigation

### `NewIdea` / project creation

**Verdict:** the start-new-project path was dead, but creation tracking/resume is still live.

What remains intentionally:
- `ActivityPanel`
- persisted `activeCreations`
- `ProjectCreationCoordinator` resume/cancel/session-monitor flow

What was removed:
- the unreachable UI route and initiation pipeline that had no production caller

### Rust `runtime_activation`

**Verdict:** not production code, but still a useful spec harness.

What changed:
- kept the subtree
- updated its module header to state clearly that it is test-only and no longer part of live activation

Reason:
- the tests still provide useful regression coverage
- the real problem was stale ownership/docs drift, not pure deadness

### Still Ambiguous

- `scripts/utils/apply-icon-mask.swift`
  - likely dead one-off utility

- `scripts/ci/test-agent-observe.sh`
  - dormant, but plausibly useful as a manual harness

- `ghosttyWindowTitleMatchesSession(...)`
  - looks like an unwired fallback; still covered only by tests

## Verification

- `cargo check --workspace --all-targets`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `swift build`
- `swift test`
- `cargo machete`

Notes:
- `cargo test --workspace` passed after the first cleanup pass.
- `core/hud-hook/tests/serve_integration` still shows an existing 5-second readiness timeout flake in full-suite mode, but isolated reruns pass.

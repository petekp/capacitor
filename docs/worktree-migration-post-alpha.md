# Worktree Migration Plan (Post-Alpha)

## Goal
Migrate Capacitor from its bespoke worktree lifecycle to Claude Code's native `--worktree` flow.

## Scope decisions
- Implement post-alpha only.
- No backward-compatibility mode for legacy Capacitor-managed worktrees.
- Capacitor orchestrates Claude CLI; it does not own `git worktree add/remove` lifecycle.

## Why
- Existing implementation is tightly coupled to `/.capacitor/worktrees/`.
- Claude now provides first-class worktree session creation.
- We want simpler ownership boundaries and less brittle path logic.

## Impacted areas
- Swift:
  - `apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift`
  - `apps/swift/Sources/Capacitor/Application/Projects/WorkstreamsManager.swift`
  - `apps/swift/Sources/Capacitor/Views/Projects/WorkstreamsPanel.swift`
  - `apps/swift/Sources/Capacitor/Support/TerminalLauncher.swift`
- Rust:
  - `core/capacitor-core/src/activation/policy.rs`
  - `core/capacitor-core/src/activation.rs` tests

## Phased implementation plan

### Phase 0: Contract and ADR
- Write ADR defining:
  - New source of truth: Claude CLI worktree mode.
  - Removed responsibilities in Capacitor (manual create/remove, branch-name retries).
  - UX changes in Workstreams panel.
- Lock a minimum Claude Code CLI version that supports:
  - `-w, --worktree [name]`
  - `--tmux` (optional)

### Phase 1: Tests first (red)
- Add failing tests that assert:
  - "New Workstream" invokes Claude CLI worktree launch.
  - No app-path invocation of `git worktree add/remove`.
  - Worktree isolation works for generic git worktree paths (not path-marker specific).
- Preserve canonicalization tests that already validate repo/worktree identity mapping.

### Phase 2: Orchestration swap
- Rewire `WorkstreamsManager.create(...)` to launch Claude with `--worktree`.
- Remove manager logic for:
  - branch collision retries
  - manual remove/destroy lifecycle
- Keep open behavior for existing worktree entries.

### Phase 3: UI simplification
- Keep:
  - "New Workstream"
  - "Open"
- Remove:
  - "Destroy"
  - "Force Destroy"
  - related manager state and messaging
- Add short explanatory copy that lifecycle is CLI-managed.

### Phase 4: Path-matching refactor
- Remove hardcoded `/.capacitor/worktrees/` marker assumptions in Swift and Rust.
- Replace with git-aware worktree equivalence logic.
- Preserve invariants:
  - Parent repo shell does not hijack a sibling worktree.
  - Shell inside same worktree still matches.

### Phase 5: Cleanup
- Delete obsolete bespoke worktree service paths.
- Architecture test suites around new behavior.
- Remove stale comments/documentation referring to managed marker paths.

### Phase 6: Verification
- Run full Swift and Rust test suites.
- Manual QA:
  - Create parallel worktree sessions from one repo.
  - Verify activation routing and state mapping remain correct.
  - Verify panel no longer exposes destructive controls.

## Acceptance criteria
- Capacitor no longer performs `git worktree add/remove` in the workstream user flow.
- "New Workstream" launches Claude native worktree behavior.
- Session activation/path matching remains isolated and correct across worktrees.
- Workspace identity remains stable between repo root and worktree paths.
- No regressions in session state visualization and terminal activation.

## Risks and mitigations
- CLI behavior drift across versions.
  - Mitigation: minimum-version check plus explicit unsupported-version error.
- Unexpected worktree path layout differences.
  - Mitigation: path-agnostic, git-aware equivalence logic.
- UX confusion after removing destroy actions.
  - Mitigation: clear panel copy explaining lifecycle ownership.

## Ready-to-start checklist (post-alpha)
- Finalize ADR.
- Confirm minimum CLI version policy.
- Land red tests first.
- Execute phases in order on a single migration branch.

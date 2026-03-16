# Resume: Harden Reducer-Owned Routing Contracts

## Mission
Continue Capacitor hardening after the activation-boundary cleanup and runtime/bootstrap/setup contract work landed. The next highest-value subsystem is the Rust reducer/routing engine, because it owns the routing facts Swift must not re-derive.

## Resume Point
- Last meaningful action: merged PR #31 (`https://github.com/petekp/capacitor/pull/31`) after landing `e0a481b Harden runtime bootstrap and hook setup contracts`, then identified `core/capacitor-core/src/reduce/mod.rs` as the next core system to harden.
- Next command or file to open: `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs:228`
- Success criterion for the next step: choose one reducer invariant, express it first as a failing Rust test or verifier rule, and keep the current verifier/test surface green.

## Current State
- Done: runtime bootstrap health is now a strict identity contract in Rust and Swift.
- Done: hook setup now handles relative `hud-hook` symlinks correctly and uninstall preserves custom inner hooks in mixed settings entries.
- Done: PR #31 is merged on GitHub with merge commit `9aa4d77`.
- Established next target: the reducer/routing engine is higher leverage than another `runtime_setup.rs` slice, even though Layer 3 still warns on `runtime_setup.rs` and `runtime_state/snapshot.rs`.
- Best first slice: prove `ReducerState::resolve_routing(...)` and the persisted routing produced by `recompute_routing()` cannot disagree for the same project/workspace/session inputs.

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- Working tree: dirty only from untracked verifier cache dirs
- Local branch state: `main` is ahead of `origin/main` by 1 with unrelated local commit `9ee3933 docs`; preserve it
- Relevant merged commits:
  - `9aa4d77 Merge pull request #31 from petekp/pkp/activation-boundary-closeout`
  - `e0a481b Harden runtime bootstrap and hook setup contracts`
- Remote base context:
  - `origin/main` currently points at `adb4565 Merge branch 'worktree-eventual-swinging-parnas'`
  - `origin/main` still contains `9aa4d77` and `e0a481b` in history

## Key Artifacts
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs:228`
  - `resolve_routing(...)` is the on-demand route query seam Swift depends on.
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs:320`
  - `recompute_routing()` synthesizes the persisted routing view; this is the most likely place for drift from on-demand routing.
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs:1689`
  - existing regression test proving attached tmux routes preserve host terminal identity from shell evidence.
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs:1738`
  - existing regression test proving non-active tmux pane routing can come from tmux inventory.
- `/Users/petepetrash/Code/capacitor/.verifier/specs/RuntimeBoundaryContracts.py:11`
  - verifier rules already guard reducer ownership for tmux terminal-app and pane inference; extend here for the next routing invariant.
- `/Users/petepetrash/Code/capacitor/.verifier/reports/layer3.json`
  - currently green overall (`A`, score `96`) with only two warnings: `runtime_setup.rs` and `runtime_state/snapshot.rs` nesting depth.

## Project Rules
- Start hardening loops with a failing test or failing verifier artifact when a good seam exists.
- Run `git worktree list` first in fresh sessions.
- Do not revert unrelated user changes.
- Bias toward TDD and verifier-backed changes over reasoning-only edits.
- Use `apply_patch` for manual file edits.
- Branches should use the `pkp/` prefix.

## Established Decisions
- The runtime boundary is an authenticated local HTTP service; Swift should consume it, not reinterpret it.
- Runtime health is an identity contract, not just a liveness ping.
- Relative hook symlinks are valid installs and must resolve relative to the symlink parent.
- The reducer owns tmux pane and attached-terminal inference so Swift does not recover routing from shell heuristics.
- The verifier is the right place to ratchet these ownership boundaries.

## Assumptions
- The reducer/routing engine is the next highest-value hardening target even though it is not the current Layer 3 warning leader.
- The safest new branch point for the next hardening slice is probably `origin/main`, not local `main`, unless the local `9ee3933 docs` commit is intentionally part of the next work.

## Verification State
- Passed before PR #31 merge:
  - `cargo test -p capacitor-core --quiet`
  - `cargo test -p capacitor-core runtime_setup::tests:: -- --nocapture`
  - `cd apps/swift && swift test --filter 'RuntimeClientTests|HookServerManagerTests|AppStateTerminalActivationTests'`
  - `./scripts/verify/verify.sh`
  - `./scripts/verify/verify.sh --layers 1 --evolve`
- Passed during the pre-commit repair loop:
  - `cargo test -p capacitor-core run_hook_test_succeeds_with_recent_service_hook_activity_and_runtime_service_health -- --nocapture`
  - `cargo test -p capacitor-core --quiet`
- Not run yet for the next slice:
  - any failing reducer-consistency regression test
  - any new reducer-specific verifier rule beyond the existing tmux ownership checks

## Rejected Paths
- Do not stay in `runtime_setup.rs` just because it still has a Layer 3 warning.
- Do not reintroduce Swift-side shell-evidence routing heuristics.
- Do not assume local `main` is a clean branch base; it has the unrelated `9ee3933 docs` commit.

## Open Questions / Risks
- First reducer invariant is still a choice:
  - persisted routing vs on-demand routing consistency
  - stale-event non-regression for routing/session state
  - tie-break behavior between active shell evidence and tmux pane inventory
- `core/capacitor-core/src/reduce/mod.rs` is ~2000 lines, so slice discipline matters; avoid a broad refactor without a narrow proof target.
- Only untracked local noise right now is:
  - `/Users/petepetrash/Code/capacitor/.verifier/specs/__pycache__/`
  - `/Users/petepetrash/Code/capacitor/scripts/verify/__pycache__/`

## Notes for the Next Agent
- `scripts/gather-git-state.sh` does not exist in this repo.
- There is no repo `copy-to-clipboard.sh`; use `/usr/bin/pbcopy`.
- If you branch for the next slice, likely start from `origin/main` with a new `pkp/` branch to avoid accidentally carrying the unrelated local `docs` commit.

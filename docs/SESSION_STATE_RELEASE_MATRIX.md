# Session State Reliability Gate v3 (Runtime Service + Operations)

- Canonical path: `docs/SESSION_STATE_RELEASE_MATRIX.md`
- Scope: Hook ingest -> local runtime service -> `capacitor-core` reducer/query -> persisted runtime artifacts -> Swift projection/stabilization (`AppState`, `SessionStateManager`, `ShellStateStore`), plus the operational checks that keep replay and soak verification wired into CI
- Policy: `P0` blocking, `P1/P2` triage-required

## Purpose

This gate protects session-state correctness in the dedicated runtime-service architecture:

1. Hook event classification must remain explicit and deterministic.
2. Replay projection must remain deterministic for the same corpus.
3. Shadow read-model parity must remain green against the canonical runtime output.
4. Reducer/query baselines must remain stable under refactors.
5. Replay verification must stay wired into pre-merge CI, and soak verification must stay wired into the nightly workflow.

## P0 Blocking Commands

```bash
bash scripts/ci/session-state-gate.sh
```

The script enforces:

1. `SS-P0-1` hook mapping integrity  
   `cargo test -p hud-hook --test session_state_mapping_gate session_state_mapping_gate_ss_p0`
2. `SS-P0-2` replay-diff determinism  
   `cargo test -p capacitor-core --test replay_diff replay_diff_corpus_matches_expected_and_is_deterministic`
3. `SS-P0-3` shadow read-model parity  
   `cargo test -p capacitor-core --test replay_diff replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot`
4. Core reducer/query baseline suites  
   `cargo test -p capacitor-core reduce` and `cargo test -p capacitor-core query`

## Operational Wiring

- Pre-merge CI runs `./scripts/ci/runtime-reliability.sh ci`
- Nightly/scheduled verification runs `./scripts/ci/runtime-reliability.sh nightly <report-path>`

`runtime-reliability.sh` is the stable operational wrapper. It always runs the runtime reliability guard and replay gate. Nightly mode additionally runs the HEM shadow soak benchmark.

## P1/P2 Non-Blocking (Triage Required)

The gate script also runs replay contract checks:

1. Replay hook event type compatibility
2. Replay mutation variant compatibility

Any failure here requires explicit triage ownership and risk note before release.

## Evidence Requirements

For releases touching hook ingest, runtime-service behavior, reducer/query logic, runtime read models, or Swift-side session/shell projection and freshness logic:

1. Attach `scripts/ci/session-state-gate.sh` output, or the equivalent section from `scripts/ci/runtime-reliability.sh`.
2. Attach relevant runtime-service health and log evidence from `~/.capacitor/runtime/`.
3. If the change affects runtime projections or derived read models, attach the relevant replay-diff evidence.
4. If the change affects Swift-side projection/stabilization, attach the relevant `swift test` evidence as well.
5. Document any non-blocking triage failures with owner and due date.

## Pass / Fail

Release passes this gate only when:

1. All P0 checks are green.
2. Any P1/P2 failures are triaged and accepted in writing.

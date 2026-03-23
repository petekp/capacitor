# Method Runner: Build Boundary and First-Success Contract

> This document freezes the decisions required before implementation begins.
> Workers and sessions should treat this as authoritative for scope, location,
> and CLI surface.

## Subsystem Boundary

The method runner is a **new Rust subsystem** at:

```
core/capacitor-core/src/method_runner/
```

Module layout:

```
method_runner/
  mod.rs              # Public API surface
  definition.rs       # YAML parsing, normalization, DefinitionLoader
  events.rs           # Event types, typed payloads, event appender
  state.rs            # State machines, projection, state.json
  storage.rs          # Lock manager, atomic writes, .method/ layout
  adapters.rs         # PromptBuilder, WorkerDispatcher, ArtifactIngestor, InteractiveIO traits
  executor.rs         # Step executor, dispatch algorithm, completion policies
  resume.rs           # Two-phase resume: replay + reconciliation
```

CLI entrypoint: `core/capacitor-core/src/bin/method_runner.rs`

### Out of Scope Until After Architecture Proof (Step 7)

These files and surfaces must NOT be modified during the tracer bullet:

- `core/capacitor-core/src/domain/run_types.rs` — existing run kernel types
- `core/capacitor-core/src/domain/types.rs` — existing domain types
- `core/capacitor-core/src/reduce/run_reducer.rs` — existing reducer
- `core/capacitor-core/src/runtime_state/snapshot.rs` — AppSnapshot
- `core/hud-hook/src/serve.rs` — runtime service
- `apps/swift/` — all Swift code
- UniFFI bindings for method-runner internals

The existing run kernel is a neighboring subsystem, not the seed. Reuse
patterns (reducer style, atomic writes), not types.

## YAML Locations

```
methods/
  library/            # Author-owned methods (product artifacts)
    spec-hardening.yaml
  fixtures/           # Test/proof fixtures
    minimal-dispatch.yaml
    pipeline-blocked.yaml
```

Rust tests read from these locations. `spec-hardening.yaml` is a real method
artifact, not test data.

## CLI Shape

```bash
# Normalize a method YAML into a frozen definition
cargo run -p capacitor-core --bin method-runner -- normalize \
  --definition <yaml-path> --root <repo-root>

# Execute a method run
cargo run -p capacitor-core --bin method-runner -- run \
  --definition <yaml-path> --root <repo-root>

# Resume an interrupted run
cargo run -p capacitor-core --bin method-runner -- resume \
  --root <repo-root>
```

## First-Success Acceptance Command

```bash
cargo run -p capacitor-core --bin method-runner -- run \
  --definition methods/fixtures/minimal-dispatch.yaml \
  --root /tmp/method-run-smoke
```

**First-success definition:** This command produces a complete `.method/` tree:

- `definition.snapshot.yaml` — frozen normalized definition
- `steps/<phase>/<step>/step.json` — static step metadata
- `locks/run.lock` — acquired and released
- `events.ndjson` — authoritative event log with correct payloads
- `state.json` — projection matching event-rebuilt state
- `artifacts/handoffs/<phase>--<step>--001--primary.md` — canonical handoff copy
- `artifacts/outputs/<name>.json` — bound output registry entry
- `steps/<phase>/<step>/attempts/001/attempt.json` — attempt metadata
- `steps/<phase>/<step>/attempts/001/input-bindings.json` — resolved inputs
- `steps/<phase>/<step>/attempts/001/output-bindings.json` — resolved outputs
- `steps/<phase>/<step>/attempts/001/relay/workers/primary/prompt-header.md`
- `steps/<phase>/<step>/attempts/001/relay/workers/primary/prompt.md`

And `state.json` can be deleted and rebuilt from `events.ndjson`.

## Canonical Handoff Headings

Shared by prompt templates and the handoff parser:

```
### Files Changed
### Tests Run
### Verification
### Verdict
### Completion Claim
### Issues Found
### Next Steps
```

Parser requires all seven. Valid `Verdict` values: `CLEAN`, `ISSUES FOUND`.
Valid `Completion Claim` values: `COMPLETE`, `PARTIAL`.

## Adapter Gate Policy

- **Green:** `compose-prompt.sh` shell contract passes AND live `codex exec`
  produces a handoff → Step 6 fully closeable.
- **Waived:** `compose-prompt.sh` shell contract passes but live `codex exec`
  is red (environment issue) → Step 6 closes with fake adapter in tests,
  noted as conditionally complete.
- **Blocked:** `compose-prompt.sh` shell contract fails → Step 6 cannot start
  until the adapter boundary is fixed.

## Minimum Cargo Dependencies (Day-Zero)

```toml
serde_yaml = "0.9"    # YAML parsing for method definitions
# thiserror already present — use for adapter-facing errors
# serde/serde_json already present — use for event/state persistence
```

No new UniFFI-facing dependencies until the summary bridge exists.

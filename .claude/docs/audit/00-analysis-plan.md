# Rust Core Audit Plan (2026-03-05)

## Scope
- Workspace members: `core/capacitor-core`, `core/hud-hook`
- Total Rust source analyzed: ~14,276 LOC
- Test baseline: `cargo test -p capacitor-core -p hud-hook` passes (239 tests)

## Known-Issues Sweep
- Read `CLAUDE.md` and `README.md` for architecture and operational constraints.
- TODO/BUG markers found in:
  - `core/capacitor-core/src/runtime_validation.rs`
  - `core/capacitor-core/src/runtime_activation/mod.rs`
- Recent commits show bug-fix churn in runtime activation and hooks wiring.

## Subsystem Decomposition

| # | Subsystem | Files | Side Effects | Priority |
|---|-----------|-------|--------------|----------|
| 1 | Hook ingress + event mapping | `core/hud-hook/src/serve.rs`, `handle.rs`, `hook_types.rs`, `runtime_client.rs` | Network (localhost), runtime snapshot writes, heartbeat writes | High |
| 2 | Reducer + snapshot persistence | `core/capacitor-core/src/lib.rs`, `ingest/mod.rs`, `reduce/mod.rs`, `storage/mod.rs`, `runtime_state/snapshot.rs` | Snapshot read/write, state transitions | High |
| 3 | Setup + hook installation | `core/capacitor-core/src/runtime_setup.rs` | Settings mutation, symlink/file ops, subprocess exec | High |
| 4 | Project discovery + stats + validation | `runtime_projects.rs`, `runtime_stats.rs`, `runtime_patterns.rs`, `runtime_validation.rs`, `runtime_boundaries.rs` | Filesystem scans and reads, CLAUDE.md write | Medium |
| 5 | Activation decision engine | `runtime_activation/*`, `domain/identity.rs`, `runtime_state/path_utils.rs` | Decisioning only (pure logic), path canonicalization | Medium |
| 6 | Ideas + storage config | `runtime_ideas.rs`, `runtime_storage.rs`, `runtime_config.rs` | Per-project markdown/json writes | Medium |

## Method
- Stateful/concurrency checklist applied to subsystems 1-3.
- Data processing/config checklist applied to subsystems 4-6.
- Evidence must include exact file/line references.

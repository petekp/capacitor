# Capacitor

A fun, glanceable, bring-your-own terminal UI for navigating multiple coding agent sessions in parallel.

## Stack

- **Platform** — Apple Silicon, macOS 14+
- **Swift App** (`apps/swift/`) — SwiftUI, 120Hz ProMotion
- **Rust Core** (`core/capacitor-core/`) — Persisted runtime ingest/reduce/query, snapshot storage, and UniFFI exports

## Commands

```bash
# Quick iteration (most common)
./scripts/dev/restart-alpha-stable.sh     # DEFAULT for agents: switch to alpha+stable, then relaunch
./scripts/dev/restart-current.sh          # Only when explicitly preserving an already-selected context
./scripts/dev/restart-alpha-frontier.sh   # Use only when frontier is explicitly requested

# Rust (when changing core/)
cargo fmt                         # Format (required before commits)
cargo clippy -- -D warnings       # Lint
cargo test                        # Test

# Formal verification
./scripts/verify/verify.sh --bootstrap   # Install verifier deps and scaffold .verifier/
./scripts/verify/verify.sh --layers 1    # Structural ownership/boundary checks
./scripts/verify/verify.sh --layers 1,2  # Structural + behavioral specs
./scripts/verify/verify.sh --grade       # Elegance audit only
./scripts/verify/verify.sh --layers 1 --evolve  # Check canonical doc/spec drift
./scripts/dev/run-tests.sh               # Full local test pass (includes verifier self-tests)

# Advanced launch/build control:
./scripts/dev/restart-app.sh --force     # Full Rust + UniFFI + Swift rebuild and relaunch
./scripts/dev/restart-app.sh --channel alpha --profile stable
```

**First-time setup:** `./scripts/dev/setup.sh`

## Verifier Notes

- The verifier is fail-closed now. Layer crashes, missing outputs, invalid configs, or missing proof artifacts write `status=error` JSON and never reuse stale green reports.
- `./scripts/verify/verify.sh --changed-only` automatically escalates to a full-scope run when files under `scripts/verify/` or `.verifier/` changed. In that case `last-run.json` reports `selected_scope="full_due_to_verifier_change"`.
- Layer 1 ownership facts should prefer code-aware kinds:
  - `identifier_ref` for symbol bans that must ignore comments/prose
  - `process_exec` for command execution ownership
  - `static_http_route` for statically derivable runtime routes
- Behavioral specs in `.verifier/specs/*.py` are now thin contract declarations. Real proof bindings live in `.verifier/specs/proof_registry.yaml`, and Swift proofs should run through `scripts/verify/run-swift-test-proof.sh` so the Rust dylib is staged before `swift test`.
- Canonical verifier docs use `VERIFIER_CLAIM(<id>): ...` markers, and structural rules must reference those ids with `claim_ids`. `--evolve` now fails only for:
  - uncovered canonical claim ids
  - rules pointing at missing claim ids
  - claim owner scopes that no longer match any modules

## Structure

```
capacitor/
├── core/capacitor-core/src/      # Rust runtime: domain/, ingest/, observation/, reduce/, query/, projection/, runtime_contracts/, runtime_service/, runtime_state/, storage/
├── core/hud-hook/src/            # Runtime-service shell plus hook/shell adapters
├── apps/swift/Sources/Capacitor/ # Swift app shell, projection/stabilization, lifecycle coordinators, runtime client, and macOS integrations
└── .claude/docs/                 # Local engineering runbooks
```

## Core Principle: Local Runtime Service Architecture

**Capacitor observes Claude Code—it doesn't replace it.**

- Read from `~/.claude/` — transcripts, config (Claude's namespace)
- Write to `~/.capacitor/` — runtime service artifacts, logs, and state (our namespace)
- Never call Anthropic API directly — invoke `claude` CLI instead
- Treat the authenticated local runtime service as the live runtime boundary
- Treat persisted runtime artifacts as storage/debug outputs, not app-facing truth
- Apply deterministic Swift-side projection and stabilization after service reads.

## Key Files

| Purpose | Location |
|---------|----------|
| CoreRuntime facade | `core/capacitor-core/src/lib.rs` |
| Runtime/domain types | `core/capacitor-core/src/domain/types.rs` |
| Runtime setup + validation | `core/capacitor-core/src/runtime_setup.rs` |
| App composition root | `apps/swift/Sources/Capacitor/Models/AppState.swift` |
| Runtime service client | `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` |
| Runtime service supervision | `apps/swift/Sources/Capacitor/Models/HookServerManager.swift` |
| Session projection + hysteresis | `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` |
| Project creation coordinator | `apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift` |
| Shell CWD tracking | `core/hud-hook/src/cwd.rs` |
| Terminal activation orchestration | `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift` |
| Terminal launch facade | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` |
| tmux command ownership | `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift` |
| UniFFI bindings | `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift` |

## State Tracking

Hooks → **hud-hook runtime service** → authenticated `/health` + `/runtime/snapshot` → Swift + tooling

- **Live runtime boundary:** local runtime service bootstrap (`~/.capacitor/runtime/runtime-service.json`)
- **Persisted runtime artifact:** `~/.capacitor/runtime/app_snapshot.json`
- **Runtime logs/artifacts:** `~/.capacitor/runtime/`
- **Hook binary:** `~/.local/bin/hud-hook`

**Resolution:** Rust owns runtime ingest/reduce/query truth; Swift owns freshness guards,
projection hysteresis, shell/session composition, and macOS-facing lifecycle behavior.

## Telemetry

For coding-agent runtime debugging, use the canonical diagnostic CLI:

```bash
./scripts/dev/agent-observe.sh diagnose   # One-shot full diagnostics
./scripts/dev/agent-observe.sh check      # Validate paths
./scripts/dev/agent-observe.sh health     # Runtime health
./scripts/dev/agent-observe.sh freshness  # Snapshot staleness
```

Full command reference: `./scripts/dev/agent-observe.sh help`
Debugging guide: `.claude/docs/debugging-guide.md`

Formal verification report path: `.verifier/reports/last-run.json`

Optional browser UI + local telemetry sink: `node scripts/transparent-ui-server.mjs` (localhost:9133)

`agent-observe.sh` and `transparent-ui-server.mjs` query the runtime service first when credentials are discoverable. They only fall back to persisted artifacts when the service bootstrap is unavailable and you need offline/debug context, and that artifact mode should be treated as degraded rather than healthy live runtime.

## Common Gotchas

- **Rebuild after Swift changes** — Run `./scripts/dev/restart-alpha-stable.sh` by default to verify changes compile and render in stable profile (use frontier only when explicitly requested)
- **Always run `cargo fmt`** — CI enforces formatting
- **Scripted rebuilds are safer than manual ones** — `./scripts/dev/restart-app.sh` regenerates UniFFI bindings, stages `libcapacitor_core.dylib`, and refreshes bundled helpers. Prefer it over ad hoc `cargo build && swift build` loops after Rust changes.
- **Manual Swift builds still need the release dylib** — If you bypass the restart scripts, run `cargo build -p capacitor-core --release`, then copy `target/release/libcapacitor_core.dylib` into `$(cd apps/swift && swift build --show-bin-path)` before `swift test` or `swift run`.
- **Hook symlink, not copy** — Use `ln -s target/release/hud-hook ~/.local/bin/hud-hook` (copying triggers Gatekeeper SIGKILL)
- **UniFFI Task shadows Swift Task** — Use `_Concurrency.Task` explicitly in async code
- **Swift app links release Rust core** — The Swift package links `../../target/release`, so Rust-side API changes need a fresh release build before standalone Swift package commands

**Full gotchas reference:** `.claude/docs/gotchas.md`

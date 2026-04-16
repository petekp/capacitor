# Capacitor

A glanceable, bring-your-own-terminal UI for navigating multiple coding agent sessions in parallel.

## Stack

- **Swift App** (`apps/swift/`) — SwiftUI, macOS 14+, Apple Silicon, 120Hz ProMotion
- **Rust Core** (`core/capacitor-core/`) — Domain types, runtime ingest/reduce/query, snapshot storage, UniFFI exports
- **Runtime Service** (`core/hud-hook/`) — Runtime-service shell plus hook/shell adapters

## Build & Test

```bash
# Rust
cargo fmt                                  # Format (required before commits)
cargo clippy -- -D warnings                # Lint
cargo test                                 # All Rust tests
cargo test -p capacitor-core               # Core crate only
cargo test -p capacitor-core --test delegation_contract  # Delegation contracts

# Swift
swift test --package-path apps/swift       # All Swift tests

# Formal verification
./scripts/verify/verify.sh --layers 1      # Structural ownership/boundary checks

# Full rebuild + relaunch
./scripts/dev/restart-alpha-stable.sh      # DEFAULT: switch to alpha+stable, relaunch
```

## Key Files

| Purpose | Location |
|---------|----------|
| CoreRuntime facade | `core/capacitor-core/src/lib.rs` |
| Domain types | `core/capacitor-core/src/domain/types.rs` |
| Runtime setup | `core/capacitor-core/src/runtime/setup/` |
| App composition root | `apps/swift/Sources/Capacitor/Models/AppState.swift` |
| Runtime service client | `apps/swift/Sources/Capacitor/Models/RuntimeClient.swift` |
| Runtime service supervision | `apps/swift/Sources/Capacitor/Models/HookServerManager.swift` |
| Session projection + hysteresis | `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift` |
| Terminal activation orchestration | `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift` |
| Terminal launch facade | `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift` |
| tmux command ownership | `apps/swift/Sources/Capacitor/Models/TmuxRouter.swift` |
| Delegation loop manager | `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift` |
| UniFFI bindings | `apps/swift/Sources/Capacitor/Bridge/capacitor_core.swift` |

## Operational Boundaries

- Read from `~/.claude/` — transcripts, config (Claude's namespace)
- Write to `~/.capacitor/` — runtime service artifacts, logs, state (our namespace)
- Never call Anthropic API directly — invoke `claude` CLI instead
- Treat the authenticated local runtime service as the live runtime boundary
- Apply deterministic Swift-side projection and stabilization after service reads

## Gotchas

- **Rebuild after Rust changes** — Run `cargo build -p capacitor-core --release` before `swift test --package-path apps/swift`
- **Refresh UniFFI bindings after Rust API changes** — Run `./scripts/dev/refresh-uniffi-bindings.sh`, then verify with `./scripts/ci/check-uniffi-bindings.sh`
- **UniFFI Task shadows Swift Task** — Use `_Concurrency.Task` explicitly in async code
- **Swift package links release Rust core** — `../../target/release`, so Rust API changes need a fresh release build
- **Hook symlink, not copy** — Use `ln -s` for hud-hook (copying triggers Gatekeeper SIGKILL)
- **Always run `cargo fmt`** — CI enforces formatting

## Language

See `.claude/docs/architecture-primer.md` for current domain terms: `Project`, `Project Key`, `Orchestrator`, `Worker`, `Worker Session`, `Run`, `Delegation Loop`, `Review`, and `Decision`.

## Conventions

- Run tests after every meaningful change
- Restart the app after Swift UI changes with `./scripts/dev/restart-alpha-stable.sh` unless explicitly told not to
- Delete replaced code in the same change — no vestigial code
- Use terms from `.claude/docs/architecture-primer.md` consistently
- Prefer `./scripts/dev/restart-alpha-stable.sh` over manual build steps

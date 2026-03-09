# Architecture Reference

## Key Paths

- Rust core facade: `core/capacitor-core/src/lib.rs`
- Rust bounded-context composition: `core/capacitor-core/src/contexts/composition.rs`
- Swift live composition root: `apps/swift/Sources/Capacitor/Composition/AppShellContainer.swift`
- Swift shell environment state: `apps/swift/Sources/Capacitor/Composition/AppState.swift`
- Architecture guard: `scripts/architecture/check_architecture_guards.sh`

## Working Rules

- Put domain and file-backed system truth in Rust.
- Put UI state and platform execution in Swift.
- Put platform or OS integration helpers in `Support/`.
- Put app-facing orchestration in `Application/`.
- Keep historical program material in `docs/archive/`.

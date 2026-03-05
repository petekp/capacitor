# Rust Core Audit Summary (2026-03-05)

## Findings by Severity
- High: 2
- Medium: 3
- Low: 1
- Critical: 0

## Top 5 Most Critical Issues
1. Ambient `PWD` fallback can misattribute hook events (`core/hud-hook/src/hook_types.rs`, `core/hud-hook/src/handle.rs`)
2. Hook verification invokes removed CLI shape (`core/capacitor-core/src/runtime_setup.rs`, `core/hud-hook/src/main.rs`)
3. Hook server body-size guard bypass when `Content-Length` is absent (`core/hud-hook/src/serve.rs`)
4. Hook-health grace can be extended by stale sessions (`core/capacitor-core/src/lib.rs`, `core/capacitor-core/src/runtime_state/snapshot.rs`)
5. Project sorting uses directory mtime instead of session activity (`core/capacitor-core/src/runtime_projects.rs`)

## Recommended Fix Order
1. Fix hook event path attribution (`resolve_cwd` fallback policy) and add regression tests for missing `cwd` payloads.
2. Fix `verify_hook_binary` to validate supported CLI paths and add tests for broken/invalid command validation.
3. Enforce hard request-body caps independent of `Content-Length`.
4. Tighten hook-health active-session criteria and add tests for stale/ready session behavior.
5. Correct project sorting to use latest session file mtime and add ordering tests.

## Verification Notes
- `cargo test -p capacitor-core -p hud-hook`: pass
- `cargo clippy -p capacitor-core -p hud-hook --all-targets -- -D warnings`: fails on existing test-lint (`unnecessary_get_then_check`) at `core/capacitor-core/src/reduce/mod.rs:883`

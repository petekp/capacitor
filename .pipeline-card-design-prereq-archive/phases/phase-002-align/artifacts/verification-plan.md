# Verification Plan: Rebuild UX — Diff + Banner

## Compilation Gate
- `cd apps/swift && swift build` must succeed
- `cargo fmt --check` must pass
- `cargo clippy -- -D warnings` must pass

## Test Gate
- `cd apps/swift && swift test` — all tests pass including new manifest decode tests
- New tests verify: manifest with swift_changes true/false/nil all decode correctly

## Manual Verification
- Rebuild app via `./scripts/dev/restart-alpha-stable.sh`
- Delegate a task that modifies Swift files
- When milestone arrives, verify:
  1. Review window shows "CHANGES" section with diff stat
  2. "Show Full Diff" expands to full diff output
  3. Banner appears when `swift_changes: true` in manifest
  4. Copy button copies the rebuild command
  5. Banner dismiss works and resets on new milestone
  6. Manifests without `swift_changes` field still work (backwards compat)

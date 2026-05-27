# Project Storage Key Alias Hardening

Date: 2026-05-26

## Scenario

Capacitor live tests often use disposable projects under `/private/tmp`. On macOS, Swift path normalization sees `/private/tmp/...` as `/tmp/...`, while Core storage previously encoded the raw path. That could split Task/Idea storage from Work Batch storage for the same visible project.

This is a correctness issue for symlinked temp/manual projects, even though normal product projects under `/Users/petepetrash/Code/...` were not affected by this specific alias.

## Source Change

Core per-project storage now normalizes the project path before choosing the Capacitor-owned storage directory:

```text
core/capacitor-core/src/runtime/storage.rs
```

Important boundary:

- `encode_path` remains lossless for historical paths and decoding.
- `project_data_dir` now uses `normalize_project_path_for_storage` before encoding live per-project storage.
- On macOS, `/private/tmp` and `/private/tmp/...` normalize to `/tmp` and `/tmp/...`, matching Swift's project-key behavior.
- Trailing slashes normalize away before storage key selection.

## Verification

Passed:

```bash
CARGO_INCREMENTAL=0 cargo test -p capacitor-core runtime::storage --lib
cargo test -p capacitor-core --lib --bins --tests
cargo build -p capacitor-core --release
swift test --package-path apps/swift --filter CapacitorProjectPathsTests
swift test --package-path apps/swift
./scripts/dev/restart-alpha-stable.sh
./scripts/dev/check-terminal-activation-state.sh --activate-debug --require-debug-frontmost
cargo fmt
git diff --check
```

Results:

```text
Core storage tests: 34 passed, 0 failed.
Broad Core verification: passed across library, bins, and integration tests.
Release Core build: passed.
Swift path test: 1 passed, 0 failed.
Full Swift verification: 947 XCTest cases, 1 skipped, 0 failed; 19 Swift Testing tests, 0 failed.
Canonical Debug restart: passed.
Strict Debug preflight: Debug app pid 51006 frontmost, no release/non-Debug Capacitor processes, no Claude processes, no recent fixture activation trace.
cargo fmt: passed.
git diff --check: passed.
```

## Result

Pass.

Newly routed temp projects now use one stable Capacitor project key for Core Task/Idea storage and Swift Work Batch state when the project is reached through either `/private/tmp/...` or `/tmp/...`.

## Remaining Risk

This change does not migrate already-written temp-project state that used the old raw `/private/tmp` key. That is acceptable for disposable fixtures. If user-visible projects are ever stored through both aliases, we should add a one-time backfill or legacy-key fallback.

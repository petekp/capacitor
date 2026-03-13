# Dead Code Sweep Report

**Scope:** full codebase
**Date:** 2026-03-13
**Estimated removable lines:** ~565 confirmed, ~990 additional lines need review

## Inventory

- Languages: Swift, Rust, JavaScript/TypeScript, Bash/Bats
- Entry points:
  - `apps/swift/Sources/Capacitor/App.swift`
  - `core/hud-hook/src/main.rs`
  - `core/capacitor-core/src/lib.rs`
  - `services/ingest-worker/src/index.js`
  - `apps/www/app/page.tsx`
- Build / test surfaces:
  - SwiftPM in `apps/swift/Package.swift`
  - Cargo workspace in `Cargo.toml`
  - Wrangler worker in `services/ingest-worker/package.json`
  - Next.js app in `apps/www/package.json`
  - GitHub Actions in `.github/workflows/ci.yml`
- Packages / units:
  - Swift macOS app
  - Rust library crate: `core/capacitor-core`
  - Rust binary crate: `core/hud-hook`
  - Cloudflare worker: `services/ingest-worker`
  - Next.js site: `apps/www`
- Estimated LOC:
  - ~137,374 lines across tracked `.swift`, `.rs`, `.js`, `.ts(x)`, `.mjs`, `.sh`, and `.bats` files
  - Note: this includes large generated FFI bridge code, so it overstates hand-written logic

## Removed

### Removed After Approval

- `scripts/ci/test-agent-observe.sh` — 565 lines
  - Removed on 2026-03-13 after approval
  - Rationale: standalone bash harness with zero references from workflows, docs, or any other script

## Confirmed Dead (high confidence)

### Orphaned Files

- None currently pending in the approved category.

## Needs Review (uncertain)

### Orphaned / Manual Utility Candidates

- `scripts/utils/apply-icon-mask.swift` — 256 lines
  - What it is: Swift utility that generates masked iconset assets
  - Why it appears dead:
    - zero references from workflows, docs, or other scripts
    - output assets already exist under `assets/AppIcon.iconset`
    - no release/build script currently calls it
  - Why not confirmed:
    - could still be an intentional manual asset-regeneration tool
  - Confidence: needs review

- `apps/www/` package — ~242 lines of app/config code plus static assets
  - What it is: standalone Next.js site with its own `package.json`
  - Why it appears dead:
    - no references from root docs, workflows, release scripts, or contributor guidance beyond the package’s own files
    - no repo-level automation builds, tests, or deploys it
  - Why not confirmed:
    - it is a self-contained package with valid entry points (`next dev/build/start`) and may intentionally be maintained out-of-band
  - Confidence: needs review

### Test-Only Production Surface

- `core/capacitor-core/src/projection/mod.rs` — 169 lines
  - What it is: `SnapshotReadModelProjector` and associated projection structs
  - Why it appears dead:
    - repo-wide usage is limited to the module’s own unit tests and `core/capacitor-core/tests/replay_diff.rs`
    - no live workspace production path calls into the projector
  - Why not confirmed:
    - the `projection` module is publicly exported from `capacitor-core`, so external consumers are theoretically possible
    - even if external consumers do not exist, this may be intentional architecture scaffolding for replay validation
  - Confidence: needs review

## Scanned But Not Flagged

- `scripts/ci/swiftformat-lint.sh` is live via `.github/workflows/ci.yml`
- `scripts/ci/test-surface-audit.sh` is live via `.github/workflows/ci.yml`
- `services/ingest-worker` dependency surface did not show any confirmed orphaned packages
- `cargo check --workspace --all-targets` did not surface obvious dead-code warnings
- Swift source scan produced many low-reference symbols, but most resolved to legitimate entry points, views, generated FFI helpers, or convention-driven test coverage

## Recommended Cleanup Order

1. Remove the confirmed orphaned script `scripts/ci/test-agent-observe.sh`
2. Decide whether the manual icon tool `scripts/utils/apply-icon-mask.swift` should be kept as unsupported-but-useful tooling or deleted
3. Decide whether `apps/www` is an intentional standalone package
4. Decide whether the Rust `projection` module is intended test-only scaffolding or production-bound architecture

# Dead Code Sweep Report

**Scope:** full codebase
**Date:** 2026-03-13
**Estimated removable lines:** ~1,760 lines still need review

## Inventory

- Languages: Swift, Rust, JavaScript or TypeScript, Bash
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
- Packages / units:
  - Swift macOS app
  - Rust library crate: `core/capacitor-core`
  - Rust binary crate: `core/hud-hook`
  - Cloudflare worker: `services/ingest-worker`
  - Next.js site: `apps/www`

## Removed

### Removed After Approval

- `scripts/ci/test-agent-observe.sh` — 565 lines
  - Removed on 2026-03-13 after approval
  - Rationale: standalone bash harness with zero references from workflows, docs, or any other script

- Swift terminal-layer dead-code cluster — ~50 lines plus matching no-op test stubs
  - Removed on 2026-03-13 after approval
  - Removed items:
    - unused private `telemetry(...)` helper in `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
    - unused `bashDoubleQuoteEscape(...)` helper in `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
    - dead `AppleScriptClient` methods `run(_:)`, `runChecked(_:)`, and `runBoolean(_:)`
    - matching dead `DefaultAppleScriptClient` implementations
    - matching dead test stubs in the Swift terminal tests
    - dead `HostTerminalOperation.activateApplication` enum case in `apps/swift/Sources/Capacitor/Models/TerminalActivationFailure.swift`
  - Verification:
    - `cd apps/swift && swift test`

## Confirmed Dead (high confidence)

- No confirmed-dead items currently pending after the approved Swift terminal-layer cleanup.

## Needs Review (uncertain)

### Orphaned / Manual Utility Candidates

- `scripts/utils/apply-icon-mask.swift` — 256 lines
  - What it is: Swift utility that generates masked iconset assets
  - Why it appears dead:
    - zero references from workflows, docs, or other scripts
    - tracked output assets already exist under `assets/AppIcon.iconset`
  - Why not confirmed:
    - could still be an intentional manual asset-regeneration tool
  - Confidence: needs review

- manual script surfaces with little or no external documentation:
  - `scripts/dev/clean-user-install.sh`
  - `scripts/dev/run-tests.sh`
  - `scripts/release/release.sh`
  - What they are: operator-facing scripts that appear to be intended for manual use
  - Why they appear suspicious:
    - they have little or no references from README, CLAUDE.md, docs, or workflows
    - current references are mostly self-documenting usage comments
  - Why not confirmed:
    - each script is a coherent end-to-end workflow and could still be intentionally invoked by humans out-of-band
  - Confidence: needs review

- `apps/www/` package — 1,344 tracked lines total, roughly a few hundred lines of actual site code plus lockfile and assets
  - What it is: standalone Next.js app with its own `package.json`
  - Why it appears dead:
    - no root README, CLAUDE.md, or CI references point contributors or automation at it
    - no repo-level automation builds, tests, or deploys it
  - Why not confirmed:
    - it is a self-contained package with valid entry points (`next dev/build/start`) and could be intentionally maintained out-of-band
  - Confidence: needs review

### Test-Only Production Surface

- `core/capacitor-core/src/projection/mod.rs` — 169 lines
  - What it is: `SnapshotReadModelProjector` and related projection structs
  - Why it appears dead:
    - in-repo usage is limited to the module’s own tests and `core/capacitor-core/tests/replay_diff.rs`
    - no live production path in this repository appears to call the projector
  - Why not confirmed:
    - the `projection` module is publicly exported from `capacitor-core`
    - this may be intentional replay-validation scaffolding or external-consumer API
  - Confidence: needs review

## Scanned But Not Flagged

- `apps/swift/Sources/Capacitor/Views/Components/PageScaffold.swift` is live via `apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift`
- `services/ingest-worker` is referenced by docs and has a coherent script surface
- `scripts/dev/agent-observe.sh` is noisy but live throughout current docs and QA workflows
- `apps/www` generated `.next/` and `node_modules/` content was excluded from analysis; only tracked package files were considered
- no intentionally skipped or obviously orphaned test suites were found in `apps/swift/Tests`, `core/*/tests`, `services/ingest-worker/test`, or `tests/`

## Recommended Cleanup Order

1. Remove the confirmed-dead Swift terminal-layer cluster:
   - `telemetry(...)`
   - `bashDoubleQuoteEscape(...)`
   - dead `AppleScriptClient` methods plus their dead stubs
   - dead `HostTerminalOperation.activateApplication` case
2. Decide whether `scripts/utils/apply-icon-mask.swift` is intentional manual tooling or stale
3. Decide whether `apps/www` is intentionally maintained or should be removed from the repo
4. Decide whether the Rust `projection` module is intentionally public scaffolding or removable test-only code

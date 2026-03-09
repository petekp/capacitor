# Release Guide

Use this guide for agent-run release preparation and verification.

Source of truth for the active app architecture still lives in:

- `architecture/CHARTER.md`
- `architecture/DECISIONS.md`
- `docs/architecture/OVERVIEW.md`
- `docs/architecture/REFERENCE.md`

Source of truth for release mechanics lives in the scripts themselves:

- `scripts/release/release.sh`
- `scripts/release/bump-version.sh`
- `scripts/release/build-distribution.sh`
- `scripts/release/verify-app-bundle.sh`
- `scripts/release/create-dmg.sh`
- `scripts/release/generate-appcast.sh`

## Preflight Before Any Release Work

The worktree should be clean, and these commands should pass before you build release assets:

```bash
git status --short
scripts/architecture/check_architecture_guards.sh --status
scripts/ci/runtime-reliability-guard.sh --status
cargo test -p capacitor-core
cargo test -p capacitor-hook
cd apps/swift && swift test
```

For honest first-run validation, test from a reset or isolated environment rather
than from a long-lived dev machine state.

## Quick Release Workflow

Default path:

```bash
./scripts/release/release.sh patch
```

Use `./scripts/release/release.sh --dry-run` for a full rehearsal without pushing or publishing.
That script is the canonical end-to-end release workflow. It also checks for a dirty
worktree and will prompt before continuing when you are not in version-bump mode.

Individual release scripts are for surgical debugging, not the default path:

```bash
./scripts/release/bump-version.sh patch
./scripts/release/build-distribution.sh --channel alpha --skip-notarization
./scripts/release/verify-app-bundle.sh
./scripts/release/build-distribution.sh --channel alpha
./scripts/release/create-dmg.sh
./scripts/release/generate-appcast.sh --sign
```

For the broader human checklist, also see `docs/PRE_RELEASE_CHECKLIST.md`, but do
not let an old dated report override the current scripts or current verification output.

## What `build-distribution.sh` Must Produce

The release app bundle must include:

- `Capacitor` app executable
- `libcapacitor_core.dylib`
- `Sparkle.framework`
- `Capacitor_Capacitor.bundle`
- bundled `capacitor-hook` binary in `Contents/Resources/`
- fresh UniFFI Swift bindings

If any of those are missing, the build is incomplete even if the app launches locally.

## One-Time Setup

### Install the hook binary for local release testing

```bash
./scripts/sync-hooks.sh --force
```

### Store notarization credentials

```bash
xcrun notarytool store-credentials "Capacitor" \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

See `docs/NOTARIZATION_SETUP.md` for the full setup guide.

## Agent Verification Checklist

After building release assets:

```bash
./scripts/release/verify-app-bundle.sh
bats tests/capacitor-hook/capacitor-hook-smoke.bats
```

Then validate the app from a fresh state:

```bash
./scripts/dev/reset-for-testing.sh
```

Key things to confirm manually:

- app launches from the built bundle, not from a stale dev build
- bundled `capacitor-hook` installs successfully on first run
- runtime snapshot updates after shell integration runs
- Sparkle metadata and version/build numbers match the intended release

## Release Gotchas

- `Sparkle.framework` must be embedded and signed. SPM link success is not enough.
- The build script regenerates UniFFI bindings. Do not hand-edit generated bindings before release.
- `capacitor-hook` must be bundled in `Contents/Resources/` or first-run install will fail.
- ZIP archives must exclude AppleDouble files. If users see "app is damaged", inspect for `._*` files.
- Sparkle compares numeric build numbers, not marketing version strings.
- Never upload a partially rebuilt asset set. Rebuild all artifacts together or not at all.

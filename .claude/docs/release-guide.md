# Release Guide

Complete procedures for building, notarizing, and distributing Capacitor releases.

## Quick Release Workflow

```bash
./scripts/release/bump-version.sh patch          # Bump version
./scripts/release/build-distribution.sh --skip-notarization  # Build without notarize
./scripts/release/verify-app-bundle.sh           # VERIFY before release!
./scripts/release/build-distribution.sh          # Full build + notarize
./scripts/release/create-dmg.sh                  # Create + notarize DMG
./scripts/release/generate-appcast.sh --sign     # Update Sparkle feed (must sign!)

gh release create v0.x.x \
  dist/Capacitor-v0.x.x-arm64.dmg \
  dist/Capacitor-v0.x.x-arm64.zip \
  dist/appcast.xml \
  --title "Capacitor v0.x.x" \
  --notes "Release notes"
```

**IMPORTANT:** See `docs/PRE_RELEASE_CHECKLIST.md` for the full verification checklist. Test from an isolated location (`/tmp`) before releasing—dev environment masks issues.

## One-Time Setup

### Install Hook Binary

```bash
./scripts/sync-hooks.sh --force
```

### Store Notarization Credentials

```bash
xcrun notarytool store-credentials "Capacitor" \
  --apple-id "your@email.com" \
  --team-id "YOUR_TEAM_ID" \
  --password "app-specific-password"
```

See `docs/NOTARIZATION_SETUP.md` for full guide.

## Release Gotchas

- **Sparkle.framework must be bundled** — Swift Package Manager links but doesn't embed frameworks. The build script copies it to `Contents/Frameworks/` and signs it.
- **Private repos break auto-updates** — Sparkle fetches appcast.xml anonymously; private GitHub repos return 404. Repo must be public for updates to work.
- **UniFFI bindings must be regenerated for releases** — The build script auto-regenerates Swift bindings from the Rust dylib. If you see "UniFFI API checksum mismatch" crashes, the bindings are stale.
- **SPM resource bundle must be copied** — `Bundle.module` only works when running via SPM. The build script copies `Capacitor_Capacitor.bundle` to `Contents/Resources/`.
- **ZIP archives must exclude AppleDouble files** — macOS extended attributes create `._*` files that break code signatures. The build script uses `ditto --norsrc --noextattr`. If users see "app is damaged", check for `._*` files.
- **Sparkle compares build numbers, not version strings** — The `sparkle:version` field must match `CFBundleVersion` (numeric build number like `202601261256`), not `CFBundleShortVersionString` (marketing version like `0.1.24`). String comparison makes "0.1.24" < "202601260928", so updates won't be offered. Use `sparkle:shortVersionString` for the display version.
- **Never manually upload individual release assets** — The v0.1.24 incident: DMG was built from a stale `apps/swift/Capacitor.app` with version 0.1.23, while the ZIP was rebuilt fresh with 0.1.24. Users who downloaded the "v0.1.24 DMG" got 0.1.23, triggering an immediate update prompt. Always run the complete `./scripts/release/release.sh` workflow, or rebuild ALL artifacts fresh if doing manual steps.

# Pre-Release Checklist

This checklist ensures distributed builds work on fresh installations. **Complete every step before publishing.**

## Why This Exists

The dev environment masks problems:

| Dev Context | Distributed Context |
|-------------|---------------------|
| `swift run` uses SPM runtime | `.app` uses macOS bundle runtime |
| `Bundle.module` finds `.build/` resources | `Bundle.module` crashes (no `.build/`) |
| Source tree has fallback paths | DMG mount has only the `.app` |
| Same macOS version | Users on different macOS versions |

## The Checklist

### 0. Terminal Activation QA (When Activation/Routing Changed)

If the release includes changes to terminal activation, tmux switching, or Ghostty AX routing, reference:

- `.claude/docs/terminal-activation-ux-spec.md` (canonical UX contract)
- `docs/manual-qa/2026-02-23-ghostty-tab-routing-manual-qa.md` (Ghostty tab-routing artifact template/report)

Required sign-off artifacts:

- [ ] Manual QA report attached to PR/issue (using canonical reporting template)
- [ ] All P0 scenarios pass (or explicit triage documented)
- [ ] Reuse scenarios show no unexpected `launchNewTerminal`
- [ ] Ghostty multi-tab/multi-window scenarios show deterministic AX routing (`tab_press` preferred, `window_raise` fallback)
- [ ] Host-hygiene gate enforced for P1 evidence (controlled terminal density or explicit isolation strategy documented)
- [ ] P2 edge/failure scenarios reviewed (fixed or explicitly accepted with rationale)
- [ ] UX POV summary included in report:
  - [ ] One-click confidence (immediate, predictable acknowledgment)
  - [ ] Context continuity (reuse existing terminal context first)
  - [ ] No surprise fan-out (new windows only as fallback)
  - [ ] Last-intent-wins confidence under rapid clicks
  - [ ] Focus stability (no post-action focus drift)

### 0.5 Session State Reliability QA (When Hook/Reducer/State Logic Changed)

If the release includes changes to hook event handling, runtime reducer/session transitions, or stop-gate behavior, run:

- `docs/SESSION_STATE_RELEASE_MATRIX.md` (canonical session-state gate)
- `docs/manual-qa/session-state-matrix-template.md` (manual evidence template)
- `scripts/ci/session-state-gate.sh` (automated gate runner)

Required sign-off artifacts:

- [ ] Session-state manual QA report attached (using canonical template)
- [ ] All `SS-P0` scenarios pass
- [ ] `SS-P0` structured log evidence captured (`gate_id`, `scenario_id`, `classification`, `transition`, `skip_reason`, `event_id`, `session_id`)
- [ ] No forbidden `SS-P0` signals (silent drops, stale override, stop-gate overrun)
- [ ] Any `SS-P1/SS-P2` failure is triaged with owner + target date + risk-acceptance note

### 0.6 Non-Demo AX UI Smoke (When Project Card/Session UI Logic Changed)

If the release includes changes to project cards, layout toggles, project details navigation, or accessibility identifiers, run:

- `bash scripts/ci/non-demo-ax-smoke.sh`

Required sign-off artifacts:

- [ ] Stable profile card AX scenario passes (real projects, no demo env)
- [ ] Frontier profile details AX scenario passes (`ax.project-details.*` + back navigation)
- [ ] Logs attached from `artifacts/manual-testing/non-demo-ax-smoke-*.log`

### 1. Pre-Build Checks

- [ ] **Rust code compiles**: `cargo build -p capacitor-core --release`
- [ ] **Swift code compiles**: `cd apps/swift && swift build`
- [ ] **No `Bundle.module` in non-DEBUG code**: `grep -r "Bundle\.module" apps/swift/Sources | grep -v "#if DEBUG"` should only show `ResourceBundle.swift` fallback (if any)

### 2. Build Distribution

```bash
./scripts/release/build-distribution.sh --skip-notarization
```

- [ ] Build completes without errors
- [ ] Resource bundle copied: check for "✓ Resource bundle copied" in output

### 3. Verify App Bundle Structure

Run the verification script:
```bash
./scripts/release/verify-app-bundle.sh
```

Or manually check:
- [ ] `ls apps/swift/Capacitor.app/Contents/MacOS/Capacitor` — executable exists
- [ ] `ls apps/swift/Capacitor.app/Contents/Frameworks/libcapacitor_core.dylib` — Rust dylib exists
- [ ] `ls apps/swift/Capacitor.app/Contents/Frameworks/Sparkle.framework` — Sparkle exists
- [ ] `ls apps/swift/Capacitor.app/Contents/Resources/Capacitor_Capacitor.bundle` — SPM resource bundle exists
- [ ] `ls apps/swift/Capacitor.app/Contents/Resources/Capacitor_Capacitor.bundle/logomark.pdf` — critical resource exists

### 4. Isolated Launch Test (CRITICAL)

**This catches issues that don't appear when testing from the source tree.**

```bash
# Extract to a clean location outside the source tree
TEST_DIR="/tmp/Capacitor-test-$(date +%s)"
mkdir -p "$TEST_DIR"
unzip -q dist/Capacitor-*.zip -d "$TEST_DIR"

# Launch from isolated location
open "$TEST_DIR/Capacitor.app"
```

- [ ] App launches without crash
- [ ] App shows WelcomeView (or main view if already set up)
- [ ] Logomark renders in WelcomeView (not the fallback sparkles icon)
- [ ] App quits cleanly via Cmd+Q

### 5. Check Logs for Warnings

If the app launched but something seems off:

```bash
# View recent logs
log show --predicate 'subsystem == "com.capacitor.app"' --last 5m
```

- [ ] No "Resource not found" warnings
- [ ] ResourceBundle shows "✅ Found resource bundle"

### 6. Notarize and Final Build

Only after all above checks pass:

```bash
./scripts/release/build-distribution.sh  # Full build with notarization
./scripts/release/create-dmg.sh
./scripts/release/generate-appcast.sh
```

### 7. DMG Launch Test

```bash
# Mount the DMG and test from there (simulates user experience)
hdiutil attach dist/Capacitor-*.dmg
open /Volumes/Capacitor/Capacitor.app
```

- [ ] App launches from mounted DMG
- [ ] No Gatekeeper warnings (notarization worked)

## Debugging Crashes

### If app crashes on launch

1. **Check crash report**:
   ```bash
   ls -lt ~/Library/Logs/DiagnosticReports/ | head -5
   open ~/Library/Logs/DiagnosticReports/Capacitor-*.crash
   ```

2. **Look for these patterns**:
   - `Bundle.module` in stack trace → ResourceBundle.swift not being used, or fallback failing
   - `uniffiEnsureInitialized` → UniFFI binding checksum mismatch, need to regenerate
   - `_assertionFailure` in resource loading → resource file missing from bundle

3. **Check resource bundle loading logs**:
   ```bash
   log show --predicate 'subsystem == "com.capacitor.app" AND category == "ResourceBundle"' --last 5m
   ```

### If crash only happens on other machines

Likely causes:
- Different macOS version (especially betas)
- Different hardware architecture (Intel vs Apple Silicon)
- User-specific permissions or security settings
- Different locale/language settings affecting resource loading

Get the crash report from the user and look for the specific failure point.

## Common Issues and Fixes

| Issue | Cause | Fix |
|-------|-------|-----|
| "App is damaged" on open | AppleDouble `._*` files in ZIP break signature | Use `ditto --norsrc --noextattr` when creating ZIP |
| `Bundle.module` crash | SPM-only API used in release | Use `ResourceBundle.url()` instead |
| UniFFI checksum mismatch | Stale Swift bindings | Regenerate bindings (build script does this) |
| Resource not found | Bundle not copied | Check build script copies to `Contents/Resources/` |
| Code signing error | Certificate issue | Check `security find-identity -v -p codesigning` |
| Notarization rejected | Hardened runtime missing | Ensure `--options runtime` in codesign |

## Version History of This Checklist

- **v0.1.11**: Added after discovering `Bundle.module` crashes only appear on fresh installs
- **v0.1.9**: Added UniFFI binding regeneration after checksum mismatch crashes
- **v0.1.8**: Added resource bundle copy after missing resources crash

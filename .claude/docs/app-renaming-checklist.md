# App Renaming Checklist

When you decide on the final app name, use this checklist to ensure everything is updated.

## What Needs to Change

### 1. Build Scripts
- [ ] `scripts/build-distribution.sh` - Update `APP_NAME`, `ZIP_NAME` prefix
- [ ] `apps/swift/build-app.sh` - Update references if any

### 2. Swift Package
- [ ] `apps/swift/Package.swift` - Update `.executable(name: "...")` and target names
- [ ] Rename directory: `apps/swift/Sources/ClaudeHUD/` → `apps/swift/Sources/{NewName}/`

### 3. Bundle Identifiers & Info.plist
- [ ] `scripts/build-distribution.sh` - Update `BUNDLE_ID` variable
- [ ] Info.plist template in build script - Update `CFBundleIdentifier`, `CFBundleName`
- [ ] Existing `apps/swift/ClaudeHUD.app/Contents/Info.plist` if it exists

### 4. Documentation
- [ ] `README.md` - Update all references
- [ ] `CLAUDE.md` - Update project name and references
- [ ] `.claude/docs/*.md` - Update references
- [ ] `docs/` - Update references in documentation

### 5. Code Files
- [ ] Swift files - Update `@main struct ClaudeHUDApp` in `App.swift`
- [ ] Any hardcoded strings in Swift UI

### 6. Repository & GitHub
- [ ] Repository name (optional, but recommended for discoverability)
- [ ] Repository description
- [ ] GitHub Topics/tags

### 7. Notarization Profile
- [ ] Update keychain profile name when setting up notarization
- [ ] Or continue using "ClaudeHUD" as the profile name (internal only)

### 8. Distribution Artifacts
- [ ] `.gitignore` - Update if you have app-name-specific ignores
- [ ] Any Homebrew Cask formula (if created)

## Recommended Approach

**Option A: Find & Replace (Simple)**
```bash
# From repository root
find . -type f -name "*.swift" -o -name "*.sh" -o -name "*.md" | \
  xargs sed -i '' 's/ClaudeHUD/NewName/g'
```

**Option B: Targeted Changes (Safer)**
Go through each file manually using the checklist above. Safer for avoiding unintended replacements.

## Things That DON'T Need to Change

- Rust crate names (`hud-core`) - these are internal
- Directory structure beyond `Sources/ClaudeHUD/`
- State files in `~/.claude/hud-*.json` - these are user-local
- Hook scripts - they're named after functionality, not the app

## After Renaming

1. Test build: `./scripts/build-distribution.sh --skip-notarization`
2. Verify app launches: `open apps/swift/{NewName}.app`
3. Check bundle identifier: `codesign -dv apps/swift/{NewName}.app | grep Identifier`
4. Update GitHub repo name and description
5. Create new release with new name

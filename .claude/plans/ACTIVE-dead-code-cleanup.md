# Dead Code Cleanup Plan

**Status:** ACTIVE
**Created:** 2026-01-26
**Purpose:** Clean up dead, vestigial, and suspicious code identified in the audit

---

## Executive Summary

The terminal/shell state detection system has accumulated **significant dead code** through multiple agent revisions. This document catalogs all findings for cleanup.

---

## 1. SWIFT: TerminalLauncher.swift

### 1.1 Duplicate Logic: Terminal Launch Scripts

**Location:** `TerminalLauncher.swift`

**Problem:** Two nearly identical implementations for launching terminals with tmux:

| Function | Lines | Purpose |
|----------|-------|---------|
| `launchTerminalWithTmuxSession(_:)` | 191-213 | Instance method, used when no tmux client attached |
| `TerminalScripts.launchTerminalWithTmux` | 795-812 | Static script fragment, used in `launch()` |

Both contain identical terminal priority logic (Ghostty → iTerm → Alacritty → kitty → Warp → Terminal).

**Recommendation:** Delete `TerminalScripts.launchTerminalWithTmux` and consolidate into the instance method, OR refactor to share implementation.

### 1.2 Overly Complicated Project Reconstruction

**Location:** `TerminalLauncher.swift:457-472`

```swift
private func launchNewTerminalForContext(context: ActivationContext) {
    let projectName = URL(fileURLWithPath: context.projectPath).lastPathComponent
    let project = Project(
        name: projectName,
        path: context.projectPath,
        displayPath: context.projectPath,
        // ... 8 more fields set to defaults
    )
    launchNewTerminal(for: project)
}
```

**Problem:** Creates a whole `Project` object just to pass `path` and `name` to `launchNewTerminal`. This is a code smell suggesting `launchNewTerminal` should accept path directly.

**Recommendation:** Add `launchNewTerminal(for path: String)` overload.

### 1.3 activateKittyRemote Always Returns True

**Location:** `TerminalLauncher.swift:423-427`

```swift
private func activateKittyRemote(context: ActivationContext) -> Bool {
    activateAppByName("kitty")
    runBashScript("kitty @ focus-window --match pid:\(context.pid) 2>/dev/null")
    return true  // ← Always returns true regardless of command success
}
```

**Problem:** Returns `true` even if kitty @ protocol isn't available or command fails. Misleading to callers expecting actual success status.

**Recommendation:** Check command exit status and return appropriately.

---

## 2. SWIFT: ActivationConfig.swift

### 2.1 Dead Parameter: windowCount

**Location:** `ActivationConfig.swift:82-91`

```swift
init(shellCount: Int, windowCount: Int = 1) {
    if shellCount <= 1 && windowCount <= 1 {
        self = .single
    } else if windowCount > 1 {  // ← Dead branch
        self = .multipleWindows
    } else {
        self = .multipleTabs
    }
}
```

**Problem:** The `windowCount` parameter is never passed from actual code. The only call site:
```swift
// TerminalLauncher.swift:320
multiplicity: TerminalMultiplicity(shellCount: shellCount)
```

The `windowCount > 1` branch is dead code.

**Recommendation:** Remove `windowCount` parameter entirely, or implement window counting if intended.

### 2.2 Unreachable Enum Case: multipleApps

**Location:** `ActivationConfig.swift:80`

```swift
case multipleApps = "apps"
```

**Problem:** This case can NEVER be set through the `init`. There's no code path that sets `multipleApps`. Yet it's handled in 6+ switch statements in `ScenarioBehavior.defaultBehavior`.

**Evidence:**
- `init` only sets: `.single`, `.multipleWindows`, or `.multipleTabs`
- No other code ever sets `.multipleApps`
- ShellMatrixPanel UI shows it but can't trigger it

**Recommendation:** Either:
1. Remove `.multipleApps` case entirely
2. Implement detection logic to actually use it

---

## 3. RUST: lock.rs

### 3.1 Dead Function: release_lock()

**Location:** `lock.rs:717-726`

```rust
/// Release a lock directory by path (legacy path-based).
///
/// **Note:** This only releases legacy path-based locks. For session-based locks,
/// use `release_lock_by_session` instead.
pub fn release_lock(lock_base: &Path, project_path: &str) -> bool {
```

**Problem:** Function is defined but NEVER called anywhere in the codebase. The comment itself says to use `release_lock_by_session` instead.

**Evidence:**
```bash
$ grep "release_lock\(lock_base" **/*.rs
# Only matches the definition itself
```

**Recommendation:** Delete function. It's legacy code from before session-based locking.

### 3.2 Dead Function: get_lock_dir_path()

**Location:** `lock.rs:805-808`

```rust
/// Get the lock directory path for a project (legacy path-based, without checking if it exists).
pub fn get_lock_dir_path(lock_base: &Path, project_path: &str) -> std::path::PathBuf {
```

**Problem:** Never called. Superseded by `get_session_lock_dir_path()`.

**Recommendation:** Delete function.

### 3.3 Dead Export: normalize_path_simple()

**Location:** `path_utils.rs:70` and `mod.rs:55`

**Problem:** Function is public and exported from `mod.rs` but only used in tests.

**Recommendation:** Make `pub(crate)` or delete if truly unnecessary.

---

## 4. VESTIGIAL PATTERNS

### 4.1 Parallel Type Systems for Terminal Apps

**Problem:** Two different enum systems for the same apps:

| Swift File | Enum | Used For |
|------------|------|----------|
| `TerminalLauncher.swift` | `TerminalApp`, `IDEApp` | Activation logic |
| `ActivationConfig.swift` | `ParentAppType` | Configuration/matrix |

These map to the same apps but have different string conversions:
- `TerminalApp.init?(fromParentApp:)` uses `contains()` matching
- `ParentAppType.init(fromString:)` uses exact `rawValue` matching

This inconsistency can cause bugs when shell-cwd.json uses slightly different strings.

### 4.2 Comment Lies About Behavior

**Location:** `ActivationConfig.swift:82`

```swift
init(shellCount: Int, windowCount: Int = 1) {
```

The default `windowCount: Int = 1` suggests multi-window detection was planned but never implemented.

---

## 5. CLEANUP CHECKLIST

### High Priority (Actual Dead Code)

- [ ] Remove `release_lock()` from `lock.rs`
- [ ] Remove `get_lock_dir_path()` from `lock.rs`
- [ ] Remove `windowCount` parameter from `TerminalMultiplicity.init`
- [ ] Remove or implement `.multipleApps` case

### Medium Priority (Code Duplication)

- [ ] Consolidate `launchTerminalWithTmuxSession` and `TerminalScripts.launchTerminalWithTmux`
- [ ] Simplify `launchNewTerminalForContext` to not create fake Project

### Low Priority (Code Quality)

- [ ] Fix `activateKittyRemote` to return actual success status
- [ ] Make `normalize_path_simple()` `pub(crate)` or remove
- [ ] Unify `TerminalApp`/`IDEApp` with `ParentAppType`

---

## 6. METRICS

| Category | Count | Risk |
|----------|-------|------|
| Dead functions (Rust) | 2 | Low - cleanup only |
| Dead parameters (Swift) | 1 | Low |
| Unreachable code paths | 2 | Medium - misleading |
| Duplicate implementations | 2 | Medium - maintenance burden |
| Type system inconsistencies | 1 | High - potential bugs |

---

## Implementation Notes

Before removing any code:
1. Verify no dynamic/reflection-based calls exist
2. Check if code is used in tests (may need test updates)
3. Run full test suite after each removal

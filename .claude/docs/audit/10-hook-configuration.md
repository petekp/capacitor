# Session 10: Hook Configuration System Audit

**Files Analyzed:** `core/hud-core/src/setup.rs`
**Focus:** settings.json modification safety
**Date:** 2026-01-27

---

## Summary

The hook configuration system handles modifying Claude Code's `~/.claude/settings.json` to register Capacitor's session tracking hooks. Overall, **the implementation is solid** with proper atomic writes and good error handling. However, there are some dead code issues and a theoretical race condition.

---

## Analysis Checklist Results

| Criterion | Status | Notes |
|-----------|--------|-------|
| Correctness | ✅ PASS | Settings modification works correctly |
| Atomicity | ✅ PASS | Uses temp file + rename pattern |
| Race Conditions | ⚠️ LOW RISK | TOCTOU window exists but is short |
| Cleanup | ✅ PASS | NamedTempFile auto-cleans on error |
| Error Handling | ✅ PASS | All paths preserve original file |
| Documentation Accuracy | ✅ PASS | Comments match implementation |
| Dead Code | ⚠️ FOUND | HookStatus::Outdated never constructed |

---

## Findings

### Finding 1: HookStatus::Outdated is Dead Code

**Severity:** Low
**Type:** Dead code
**Location:** `setup.rs:56-59`, `engine.rs:861`

**Problem:**
The `HookStatus::Outdated` variant is defined but never constructed anywhere in the codebase. The only usage is in pattern matching at `engine.rs:861`, which can never execute.

**Evidence:**
```rust
// setup.rs:56 - Definition exists
pub enum HookStatus {
    NotInstalled,
    Outdated {
        current: String,
        latest: String,
    },
    Installed { version: String },
    // ...
}

// setup.rs:272 - Only Installed is ever constructed
HookStatus::Installed {
    version: "binary".to_string(),  // Hardcoded, no version comparison
}
```

Searching the entire codebase confirms `Outdated {` only appears in the definition and pattern matching, never construction.

**Impact:**
- `HookIssue::ConfigOutdated` is also unreachable
- UI code handling `Outdated` case will never execute
- Confuses maintainers about expected behavior

**Recommendation:**
Either:
1. Remove `HookStatus::Outdated` and `HookIssue::ConfigOutdated` as dead code
2. OR implement actual version checking to populate this variant

---

### Finding 2: TOCTOU Race Condition in Settings Modification

**Severity:** Low
**Type:** Race condition
**Location:** `setup.rs:619-696`

**Problem:**
The `register_hooks_in_settings` function has a time-of-check-time-of-use window:

```
1. Read settings.json (line 619-632)
2. [Window where another process could modify settings.json]
3. Modify in memory (line 634-670)
4. Write back atomically (line 672-696)
```

If another process (Claude Code, another Capacitor instance) modifies `settings.json` during this window, those changes will be lost.

**Evidence:**
```rust
// Line 619: Read
let mut settings: SettingsFile = if settings_path.exists() {
    let content = fs::read_to_string(&settings_path)?;
    serde_json::from_str(&content)?
} ...

// ... time passes, modifications happen in memory ...

// Line 692: Atomic write (but may clobber concurrent changes)
temp_settings.persist(&settings_path)?;
```

**Impact:**
- Low probability: window is short (microseconds)
- Low frequency: users rarely have concurrent settings modifications
- Moderate severity if triggered: other settings changes would be lost

**Recommendation:**
Accept the risk. File locking would add complexity for a rare edge case. Document this limitation in the CLAUDE.md gotchas if it ever becomes a real issue.

---

### Finding 3: Misleading Function Name

**Severity:** Low
**Type:** Code smell
**Location:** `setup.rs:451`

**Problem:**
`normalize_hud_hook_config` has dual responsibilities:
1. Normalizes hook config (updates command path, async/timeout settings)
2. Returns whether it found a HUD hook

The name only describes the first behavior.

**Evidence:**
```rust
fn normalize_hud_hook_config(
    &self,
    hook_config: &mut HookConfig,
    needs_matcher: bool,
    is_async: bool,
) -> bool {  // Returns whether HUD hook was found
    let mut has_hud_hook = false;
    // ... normalization logic ...
    has_hud_hook  // Also acts as a detector
}
```

**Recommendation:**
Consider renaming to `normalize_and_detect_hud_hook` or splitting into two functions.

---

## Positive Findings

### Atomic Write Pattern ✅

The settings modification correctly uses the temp-file-and-rename pattern:

```rust
// Create temp in same directory (ensures same filesystem for atomic rename)
let mut temp_settings = NamedTempFile::new_in(settings_dir)?;

// Write content
temp_settings.write_all(content.as_bytes())?;
temp_settings.flush()?;

// Atomic rename
temp_settings.persist(&settings_path)?;
```

This ensures that if the process crashes mid-write, the original `settings.json` is preserved.

### Preserves Unknown Settings ✅

The `SettingsFile` struct uses `#[serde(flatten)]` to preserve unknown fields:

```rust
#[derive(Debug, Default, Serialize, Deserialize)]
struct SettingsFile {
    hooks: Option<HashMap<String, Vec<HookConfig>>>,
    #[serde(flatten)]
    other: HashMap<String, serde_json::Value>,  // Preserves everything else
}
```

This follows the sidecar principle: we only modify hooks, never removing or changing other settings.

### Corrupt JSON Handling ✅

Parse errors return a helpful message without clobbering the file:

```rust
serde_json::from_str(&content).map_err(|e| HudFfiError::General {
    message: format!(
        "Failed to parse settings.json (file may be corrupted): {}. \
         Please fix the JSON syntax or delete the file to start fresh.",
        e
    ),
})?
```

Test at line 891-907 confirms this behavior.

### Symlink Strategy ✅

The binary installation correctly uses symlinks rather than copying:

```rust
// IMPORTANT: We use symlinks instead of copying because:
// - Copied adhoc-signed binaries get SIGKILL'd by macOS Gatekeeper
// - Symlinks preserve the original binary's code signature
symlink(&source_abs, &dest_path)?;
```

This matches the documented gotcha in CLAUDE.md about hook binary symlinks.

---

## Test Coverage Assessment

The module has good test coverage:

| Test | What it verifies |
|------|------------------|
| `test_check_hooks_not_installed` | Detects missing hooks |
| `test_register_hooks_in_settings` | Creates all required events |
| `test_policy_blocks_*` | Respects disableAllHooks/allowManagedHooksOnly |
| `test_install_hooks_checks_binary` | Binary check before registration |
| `test_does_not_clobber_existing_settings` | Preserves other settings |
| `test_register_hooks_fails_on_corrupt_json` | Doesn't overwrite corrupt files |
| `test_hooks_registered_checks_all_critical_events` | Detects partial registration |
| `test_hooks_registered_checks_matchers` | Validates matcher configuration |
| `test_install_binary_source_not_found` | Handles missing source |

**Note:** Binary installation tests that modify `~/.local/bin/hud-hook` were removed (see comment at line 963-969) because they were breaking production systems during development.

---

## Action Items

| Priority | Issue | Action |
|----------|-------|--------|
| Low | HookStatus::Outdated dead code | Remove or implement versioning |
| Low | Misleading function name | Rename normalize_hud_hook_config |
| None | TOCTOU race | Accept risk, document if needed |

---

## Conclusion

The hook configuration system is well-implemented with proper safety measures. The atomic write pattern and error handling protect against corruption. The only actionable issue is the dead `HookStatus::Outdated` code path, which should be removed for clarity.

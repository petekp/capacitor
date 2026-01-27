# Session 7: Shell State Store (Swift) Audit

**Date:** 2026-01-26
**Files Analyzed:** `apps/swift/Sources/Capacitor/Models/ShellStateStore.swift`
**Focus:** Reading/parsing, timestamp handling, Swift concurrency patterns

---

## Executive Summary

The Shell State Store is a well-structured, minimal component for polling shell CWD state. It correctly handles the documented `.withFractionalSeconds` timestamp gotcha and uses appropriate staleness thresholds.

**One medium-severity issue found:** The polling Task pattern may violate Swift 6 strict concurrency rules, though it likely works in practice due to implicit actor isolation inheritance.

---

## Architecture Context

```
┌─────────────────────────────────────────────────────────────────┐
│                        Consumers                                │
├─────────────────────────────────────────────────────────────────┤
│  ActiveProjectResolver     │ Uses mostRecentShell for fallback │
│  SetupRequirements         │ Checks if shell integration works │
│  ShellIntegrationChecker   │ Verifies shell state is populated │
│  ShellMatrixPanel          │ Debug view of shell state         │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                     ShellStateStore                             │
│ ─────────────────────────────────────────────────────────────── │
│  - Polls ~/.capacitor/shell-cwd.json every 500ms               │
│  - Filters stale shells (>10 minutes old)                      │
│  - Provides mostRecentShell computed property                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│              shell-cwd.json (written by Rust)                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Analysis Checklist Results

### 1. Correctness ✅

**Timestamp Handling:**
The code correctly implements the documented `.withFractionalSeconds` requirement:

```swift
// ShellStateStore.swift:65-66
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
```

This matches the Rust side which uses `chrono::DateTime<Utc>` serialized as RFC3339 with nanosecond precision.

**Staleness Filtering:**
The 10-minute staleness threshold is correctly applied:

```swift
// ShellStateStore.swift:87-89
let threshold = Date().addingTimeInterval(-Constants.shellStalenessThresholdSeconds)
return state?.shells
    .filter { $0.value.updatedAt > threshold }
```

### 2. Atomicity ✅

Not applicable—this component only reads data. Atomicity is handled by the Rust writer (covered in Session 6).

### 3. Race Conditions ⚠️

**Finding 1: Unstructured Task Actor Isolation (Swift 6 Concern)**

**Severity:** Medium
**Type:** Potential concurrency bug
**Location:** `ShellStateStore.swift:46-51`

**Problem:**
The polling Task is not explicitly annotated with `@MainActor`:

```swift
func startPolling() {
    pollTask = _Concurrency.Task { [weak self] in
        while !_Concurrency.Task.isCancelled {
            self?.loadState()  // ← Calls @MainActor method from unstructured Task
            try? await _Concurrency.Task.sleep(nanoseconds: Constants.pollingIntervalNanoseconds)
        }
    }
}
```

In Swift 6 with strict concurrency checking, calling `self?.loadState()` (a main-actor-isolated method) from an unstructured Task without explicit actor annotation may:
- Cause a compile error in strict mode
- Require an implicit actor hop, adding latency

**Evidence:**
- `ShellStateStore` is annotated `@MainActor`, making all instance methods main-actor-isolated
- Unstructured Tasks do NOT inherit actor context from their creation point
- The `loadState()` method synchronously mutates `state`, which is main-actor-isolated

**Recommendation:**
Explicitly mark the Task closure as `@MainActor`:

```swift
pollTask = Task { @MainActor [weak self] in
    while !Task.isCancelled {
        self?.loadState()
        try? await Task.sleep(nanoseconds: Constants.pollingIntervalNanoseconds)
    }
}
```

**Impact if not fixed:**
- Currently works because Swift likely performs an implicit actor hop
- May cause compile errors when migrating to Swift 6 strict concurrency
- Could theoretically cause data races if the implicit hop is removed in future Swift versions

### 4. Cleanup ✅

The `stopPolling()` method properly cancels the task:

```swift
func stopPolling() {
    pollTask?.cancel()
    pollTask = nil
}
```

The polling loop checks `Task.isCancelled` before sleeping, ensuring clean shutdown.

### 5. Error Handling ✅

**Silent Failures (Documented in Session 6):**
Both data loading and JSON parsing failures are handled silently:

```swift
guard let data = try? Data(contentsOf: stateURL) else { return }
guard let decoded = try? decoder.decode(ShellCwdState.self, from: data) else { return }
```

This is acceptable because:
- The Rust side uses atomic writes (corruption is rare)
- Polling retries every 500ms
- Silent failures don't block the UI

### 6. Documentation Accuracy ✅

Comments are accurate and descriptive:
- Line 30-31 explains the staleness threshold rationale
- Line 83-85 documents `mostRecentShell` behavior

### 7. Dead Code ✅

No dead code found. All public API is used by consumers:
- `startPolling()` / `stopPolling()` — Called by AppState
- `mostRecentShell` — Used by ActiveProjectResolver
- `hasActiveShells` — Used by SetupRequirements (transitively)
- `state` — Used by ShellIntegrationChecker

---

## Consumer Analysis

### ActiveProjectResolver Integration

`ActiveProjectResolver.swift` uses `shellStateStore.mostRecentShell` as a **fallback** when no Claude sessions are active (Priority 2 in resolution order):

```swift
// ActiveProjectResolver.swift:76-83
// Priority 2: Shell CWD (fallback when no Claude sessions are running)
if let (project, pid, app) = findActiveShellProject() {
    activeProject = project
    activeSource = .shell(pid: pid, app: app)
    return
}
```

**Finding 2: Consistent Staleness Handling**

**Severity:** Low (informational)
**Type:** Design verification
**Location:** Multiple files

**Observation:**
Staleness is checked in one place (`ShellStateStore.mostRecentShell`) and all consumers benefit from this filtering. This is correct—there's no redundant staleness checking.

The 10-minute threshold was chosen to:
- Filter out truly abandoned shells
- Allow for idle periods during Claude sessions (shell timestamps don't update while Claude is running)

### SetupRequirements Integration

`SetupRequirements.swift` checks shell integration status using two methods:

```swift
if let store = shellStateStore, ShellIntegrationChecker.isConfigured(shellStateStore: store) {
    // Has active shells
} else if ShellIntegrationChecker.stateFileExists() {
    // File exists but maybe empty/stale
}
```

**Note:** `isConfigured()` checks for non-empty shells (line 161), NOT non-stale shells. This is intentional—setup detection shouldn't be affected by staleness.

---

## Duplicate Timestamp Parsing

**Finding 3: Redundant ISO8601 Formatters**

**Severity:** Low
**Type:** Minor inefficiency
**Location:** `ShellStateStore.swift:65`, `ActiveProjectResolver.swift:94`

**Problem:**
Both files create their own `ISO8601DateFormatter` with identical configuration:

```swift
// ShellStateStore.swift:65-66
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

// ActiveProjectResolver.swift:94-95
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
```

**Recommendation:**
Consider creating a shared formatter extension. Not critical—the formatter is cheap to create.

---

## Cross-Reference with CLAUDE.md Gotchas

| Gotcha | Verified in Code |
|--------|------------------|
| "Rust↔Swift timestamps — Use custom decoder with .withFractionalSeconds" | ✅ `ShellStateStore.swift:66` |
| "Swift 6 concurrency — Views initializing @MainActor types need @MainActor on the view struct" | ⚠️ Related issue found (Finding 1) |

---

## Recommendations

### Should Fix

1. **Add `@MainActor` to polling Task** (Finding 1)
   - Prevents future Swift 6 strict concurrency issues
   - Makes actor isolation explicit

### Consider

2. **Shared timestamp formatter** (Finding 3)
   - Minor code deduplication
   - Low priority

### No Action Required

3. **Silent error handling** — Correct for this polling pattern
4. **Staleness threshold** — 10 minutes is appropriate

---

## Summary

| Checklist Item | Status | Notes |
|----------------|--------|-------|
| Correctness | ✅ Pass | Timestamp handling is correct |
| Atomicity | ✅ N/A | Read-only component |
| Race Conditions | ⚠️ Medium | Task actor isolation should be explicit |
| Cleanup | ✅ Pass | Proper cancellation |
| Error Handling | ✅ Pass | Silent failures are appropriate |
| Documentation | ✅ Pass | Comments match behavior |
| Dead Code | ✅ Pass | All code is used |

**Overall Assessment:** The Shell State Store is well-designed with one Swift 6 concurrency concern that should be addressed for future-proofing.

# Session 11: Project Resolution Audit

**File:** `apps/swift/Sources/Capacitor/Models/ActiveProjectResolver.swift`
**Date:** 2026-01-27
**Focus:** Focus override logic, priority resolution

---

## Overview

`ActiveProjectResolver` determines which project should be shown as "active" in the UI. It implements a priority-based resolution system with manual override support.

### Resolution Priority (from `resolve()`)

1. **Priority 0: Manual override** — Set when user clicks a project card
2. **Priority 1: Most recent Claude session** — Sessions with locks, sorted by `updatedAt`
3. **Priority 2: Shell CWD** — Fallback when no Claude sessions are running

### Data Flow

```
User clicks project
    ↓
AppState.launchTerminal(for:)
    ↓
ActiveProjectResolver.setManualOverride(project)
    ↓
ActiveProjectResolver.resolve()
    ↓
Check if shell navigated to project with active session → clear override if so
    ↓
Return active project + source
```

---

## Analysis Checklist Results

### 1. Correctness ✅ PASS

The implementation matches the documented behavior:

**Documentation (docstring lines 36-39):**
> The override persists until:
> - User clicks on a different project
> - User navigates to a project directory that has an active Claude session

**Implementation (lines 48-56):**
```swift
if let override = manualOverride,
   let (shellProject, _, _) = findActiveShellProject(),
   shellProject.path != override.path {
    if let shellSessionState = sessionStateManager.getSessionState(for: shellProject),
       shellSessionState.isLocked {
        manualOverride = nil
    }
}
```

**Verification:**
- ✅ Clicking a different project → `setManualOverride()` replaces old override
- ✅ Navigating to project with active session → override cleared (lines 52-54)
- ✅ Navigating to project WITHOUT active session → override persists (prevents timestamp racing)

### 2. Atomicity ✅ PASS (N/A)

No file I/O in this class. All state mutations are in-memory on `@MainActor`.

### 3. Race Conditions ✅ PASS

- Class is `@MainActor`, serializing all access on the main thread
- The "timestamp racing" mentioned in comments (line 47) refers to EXTERNAL data sources (shell vs Claude), not internal race conditions
- The override-only-clears-for-active-sessions logic specifically prevents this external race

### 4. Cleanup ✅ PASS (N/A)

No resources to clean up. `manualOverride` is a simple in-memory reference that gets replaced or nilled.

### 5. Error Handling ✅ PASS

No error paths. All operations are:
- Dictionary lookups with optional handling
- Array operations with safe max/filter
- Path string comparisons

### 6. Documentation Accuracy ✅ PASS

| Location | Statement | Implementation | Status |
|----------|-----------|----------------|--------|
| Lines 36-39 | Override persists until click/navigate+active | Lines 48-56, 61-64 | ✅ Accurate |
| Lines 46-47 | Prevents timestamp racing | Shell override only clears with active session | ✅ Accurate |
| Lines 67-69 | Claude sessions have accurate timestamps | Uses `updatedAt` from hook events | ✅ Accurate |
| Lines 76-78 | Shell timestamps only update on prompt | External behavior, documented correctly | ✅ Accurate |
| Lines 117-119 | Active vs passive session separation | `isActive` check on lines 120-122 | ✅ Accurate |

### 7. Dead Code ✅ PASS

No dead code found. All methods traced to callers:

| Method | Callers |
|--------|---------|
| `init(...)` | `AppState.init()` |
| `updateProjects(_:)` | `startShellTracking()`, `loadDashboard()` |
| `setManualOverride(_:)` | `launchTerminal(for:)` |
| `resolve()` | `refreshSessionStates()`, `launchTerminal(for:)` |

---

## Design Analysis

### Focus Override Mechanism

The focus override solves a specific UX problem: **timestamp racing**.

**Problem:** When user clicks a project card:
1. Terminal is launched for that project
2. Shell CWD updates (tracked in `~/.capacitor/shell-cwd.json`)
3. Meanwhile, another Claude session might have more recent `updatedAt`
4. Without override, the UI would jump to the "more recent" project

**Solution:** Override persists until user explicitly switches to another project OR navigates to a project with active Claude session (which signals intentional context switch).

### Session Priority Logic

The `findActiveClaudeSession()` function (lines 91-134) implements sophisticated prioritization:

1. **Active states** (Working/Waiting/Compacting) always beat **passive states** (Ready)
2. Within each category, most recent `updatedAt` wins
3. Fallback chain: `updatedAt` → `stateChangedAt` → `Date.distantPast`

This ensures:
- A session you're actively using won't lose focus to one that just finished
- Recent activity is preferred over stale sessions

### Shell Fallback

The shell-based resolution (lines 76-83) only activates when no Claude sessions are running. This is correct because:
- Claude sessions have precise timestamps (updated on every hook event)
- Shell timestamps only update on prompt display
- During long Claude operations, shell timestamp goes stale

---

## Findings

### Finding 1: Well-Designed Anti-Racing Mechanism ✅ NO ACTION

**Type:** Design validation
**Location:** Lines 48-56

The override-only-clears-for-active-sessions pattern is a clever solution to the timestamp racing problem. The documentation accurately describes this, and the implementation correctly implements it.

### Finding 2: Implicit Override Replacement

**Severity:** Info (Not a bug)
**Type:** Implicit behavior
**Location:** Line 41

**Observation:**
There's no explicit `clearManualOverride()` method. The override is either:
- Replaced by a new override (clicking different project)
- Cleared by navigation to project with active session

**Assessment:**
This is intentional. The absence of a "clear without replacement" operation prevents the UI from falling back to timestamp-based resolution unexpectedly. Users must always explicitly choose a project.

### Finding 3: `projectContaining` Uses Child-Path Matching

**Severity:** Info
**Type:** Design note
**Location:** Lines 148-155

```swift
if path == project.path || path.hasPrefix(project.path + "/") {
    return project
}
```

**Observation:**
For shell CWD matching, child paths ARE matched to parent projects (e.g., shell in `/project/src` matches project `/project`). This is DIFFERENT from the lock system's exact-match-only policy.

**Assessment:**
This is correct behavior. Shell CWD should match parent projects because:
- Users navigate within project directories
- The shell being in `/project/src` means they're working in `/project`

This is NOT inconsistent with lock exact-match because:
- Locks are about which SPECIFIC directory has a Claude session
- Shell matching is about which PROJECT the user is working in

---

## Dependencies Audited

### SessionStateManager

**File:** `SessionStateManager.swift`
**Used:** `getSessionState(for:)` returns `ProjectSessionState?`

- ✅ Returns cached state from Rust engine
- ✅ State includes `isLocked`, `sessionId`, `state`, `updatedAt`, `stateChangedAt`
- ✅ No side effects in getter

### ShellStateStore

**File:** `ShellStateStore.swift`
**Used:** `mostRecentShell` returns `(pid: String, entry: ShellEntry)?`

- ✅ Filters by 10-minute staleness threshold
- ✅ Returns most recent non-stale shell
- ✅ Polls `~/.capacitor/shell-cwd.json` every 500ms

---

## Conclusion

`ActiveProjectResolver` is well-designed and correctly implemented. The focus override mechanism elegantly solves the timestamp racing problem without introducing new bugs.

**Key Insights:**
1. Override replacement (not clearing) is intentional
2. Shell child-path matching is correct and different from lock exact-match by design
3. Active/passive session separation ensures good UX during state transitions
4. All documentation is accurate

**No bugs or issues found.**

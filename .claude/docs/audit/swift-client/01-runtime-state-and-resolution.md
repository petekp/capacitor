# Runtime State And Resolution Audit

### [RUNTIME STATE] Finding 1: Metadata Freeze When Any Stabilization Hold Occurs

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:125`, `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:131`, `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:155`

**Problem:**
When `stabilized != merged` (for example one project hits idle hysteresis), attribution and latest-session maps are reverted globally to previous values. Unrelated projects in the same snapshot can lose fresh metadata updates.

**Evidence:**
`nextAttributions` and `nextLatestSessionIds` choose either full new maps or full old maps; there is no per-project fallback.

**Recommendation:**
Perform per-project fallback: keep fresh metadata for unchanged projects and preserve prior metadata only for paths whose display state is intentionally held.

### [RUNTIME STATE] Finding 2: Stale Snapshot Suppression Does Not Protect Shell State

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/AppState.swift:361`, `apps/swift/Sources/Capacitor/Models/AppState.swift:381`

**Problem:**
Generation checks drop stale session-state updates, but stale shell-state updates are still applied afterward.

**Evidence:**
On stale generation, `MainActor.run` returns early, then `shellStateStore.applyRuntimeShellState(...)` executes unconditionally.

**Recommendation:**
Gate shell-state application with the same generation check (or move both session/shell commits behind one stale guard).

### [RUNTIME STATE] Finding 3: Runtime Fetch Errors Can Leave UI State Stale Indefinitely

**Severity:** Medium
**Type:** Design flaw
**Location:** `apps/swift/Sources/Capacitor/Models/AppState.swift:386`, `apps/swift/Sources/Capacitor/Models/AppState.swift:397`

**Problem:**
On repeated runtime fetch failures, session states are neither cleared nor degraded. UI can keep stale activity forever.

**Evidence:**
Error path only logs and updates context; it never writes a replacement state nor triggers stale expiration path.

**Recommendation:**
Introduce failure hysteresis (for example N consecutive failures -> clear/mark states as unavailable) and surface this condition in UI diagnostics.

### [RUNTIME STATE] Finding 4: Activity Priority Can Preserve Older Session Metadata

**Severity:** Medium
**Type:** Design flaw
**Location:** `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:557`, `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:464`

**Problem:**
Direct-match conflict resolution prefers active-state class over recency, then stale working can be downgraded to ready. This can select older session metadata that is no longer most recent.

**Evidence:**
`shouldReplace` checks activity priority before timestamp; stale downgrade occurs later during mapping.

**Recommendation:**
Apply staleness normalization before candidate arbitration, or compare recency first when candidate activity is stale.

### [RUNTIME STATE] Finding 5: File Header Claims Conflict With Actual Swift-Side Logic

**Severity:** Low
**Type:** Stale docs
**Location:** `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:6`, `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:11`

**Problem:**
Header says state logic lives in Rust and class is a passthrough, but this file implements matching, staleness downgrade, empty-snapshot hold, and idle hysteresis.

**Evidence:**
Substantial logic exists in `mergeRuntimeProjectStates` and stabilization methods.

**Recommendation:**
Update header comments to match current responsibility boundaries.

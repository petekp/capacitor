# Creation And Ingestion Audit

### [INGESTION] Finding 1: Drag-Drop DispatchGroup Race Can Drop Valid URLs

**Severity:** High
**Type:** Race condition
**Location:** `apps/swift/Sources/Capacitor/Models/AppState.swift:797`, `apps/swift/Sources/Capacitor/Models/AppState.swift:804`, `apps/swift/Sources/Capacitor/Models/AppState.swift:810`

**Problem:**
`group.leave()` happens before main-queue append to `urls`. `group.notify` can run first and observe `urls` as empty.

**Evidence:**
`defer { group.leave() }` executes immediately after callback; append is deferred via `DispatchQueue.main.async`.

**Recommendation:**
Append synchronously inside callback before `leave`, or perform both append and leave on the same queue deterministically.

### [CREATION] Finding 2: Cancelled Creations Can Be Reactivated By Session Monitor

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/AppState.swift:1377`, `apps/swift/Sources/Capacitor/Models/AppState.swift:1608`, `apps/swift/Sources/Capacitor/Models/AppState.swift:1624`

**Problem:**
`cancelCreation` sets `.cancelled`, but background session monitor still promotes the same creation back to `.inProgress` if it later discovers a session file.

**Evidence:**
`startSessionMonitor` does not guard against terminal statuses before calling `updateCreationStatus(..., .inProgress, ...)`.

**Recommendation:**
Track monitor tasks per creation and cancel them on terminal status; add status guard before any state transition.

### [CREATION] Finding 3: Session Attribution For New Creations Is Nondeterministic

**Severity:** Medium
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/AppState.swift:1621`, `apps/swift/Sources/Capacitor/Models/AppState.swift:1623`

**Problem:**
`newSessions.first` is chosen from an unordered `Set`, so selected session ID is unstable when multiple new sessions appear.

**Evidence:**
`newSessions` is `Set<String>` and first element selection is unspecified.

**Recommendation:**
Sort candidates by file creation/modification date (or lexicographically with explicit convention) before selecting.

# Terminal Activation And Process Audit

### [TERMINAL] Finding 1: Unsynchronized `Data` Mutation Across Process Callbacks

**Severity:** High
**Type:** Race condition
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:769`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:770`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:776`

**Problem:**
`outputData` is appended from both `readabilityHandler` and `terminationHandler` without synchronization. Concurrent mutation can corrupt output or crash.

**Evidence:**
Both closures append to the same mutable buffer; no lock/serial queue/actor protects it.

**Recommendation:**
Serialize buffer writes (actor or dedicated serial queue) or collect output using a single read path after process exit.

### [TERMINAL] Finding 2: Cancellation Does Not Terminate Child Process

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:219`, `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift:754`

**Problem:**
Launch arbitration cancels tasks, but underlying shell process execution has no timeout and no cancellation handler. Hung commands can outlive request cancellation.

**Evidence:**
`runBashScriptWithResult` wraps a continuation and does not terminate `Process` on caller cancellation.

**Recommendation:**
Use `withTaskCancellationHandler` to terminate process on cancel, and add a hard timeout for defensive completion.

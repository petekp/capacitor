# Setup And Lifecycle Audit

### [SETUP] Finding 1: Onboarding Can Crash If `CoreRuntime` Initialization Fails

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/SetupRequirements.swift:92`, `apps/swift/Sources/Capacitor/Models/SetupRequirements.swift:94`, `apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift:8`

**Problem:**
`SetupRequirementsManager` uses `fatalError` when `CoreRuntime` cannot initialize. `WelcomeView` constructs this manager eagerly, so onboarding can hard-crash instead of showing a recoverable error.

**Evidence:**
Initializer fallback explicitly calls `fatalError("Failed to create CoreRuntime")`.

**Recommendation:**
Replace fatal crash with surfaced setup error state and actionable recovery UI.

### [DETAILS] Finding 2: Main-Actor Blocking Git Calls During Sensemaking

**Severity:** High
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift:4`, `apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift:245`, `apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift:283`, `apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift:305`, `apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift:327`

**Problem:**
`ProjectDetailsManager` is `@MainActor`, but it executes blocking git subprocesses with `waitUntilExit()`. Slow repo commands freeze UI and other main-actor work.

**Evidence:**
`gatherSensemakingContext` calls `getRecentFiles/getGitBranch/getLastCommitMessage`, each blocking on process exit.

**Recommendation:**
Move git subprocess work off main actor (detached task or actor-isolated worker) and return back to main actor only for UI state mutation.

### [HOOK SERVER] Finding 3: `stop()` Blocks Main Actor On Process Exit

**Severity:** Medium
**Type:** Design flaw
**Location:** `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:8`, `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:124`

**Problem:**
`HookServerManager` is `@MainActor`, and `stop()` calls `waitUntilExit()`. Slow shutdown blocks app responsiveness.

**Evidence:**
Synchronous wait is executed inside main-actor-isolated class method.

**Recommendation:**
Terminate asynchronously and observe completion without blocking the main actor.

### [HOOK SERVER] Finding 4: In-Flight Health Checks Can Restart A Server After Stop

**Severity:** Medium
**Type:** Race condition
**Location:** `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:88`, `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:107`, `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:115`, `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:172`

**Problem:**
`checkHealth()` launches untracked async work. `stop()` does not cancel pending checks, so late failure callbacks can trigger `handleUnexpectedExit()` and restart unexpectedly.

**Evidence:**
Health check task is fire-and-forget; restart path has no stop-intent guard.

**Recommendation:**
Track and cancel health-check task(s), and add explicit lifecycle epoch/stop token checks before restart.

### [HOOK SERVER] Finding 5: PID Adoption Can Misidentify Unrelated Process

**Severity:** Medium
**Type:** Bug
**Location:** `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:59`, `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:60`, `apps/swift/Sources/Capacitor/Models/HookServerManager.swift:193`

**Problem:**
Startup adopts any live PID from pidfile using `kill(pid, 0)` only. PID reuse can falsely classify unrelated process as the hook server.

**Evidence:**
No binary identity or port ownership verification before adopting and moving to `.starting`.

**Recommendation:**
Verify process identity (command line) and/or port ownership before adoption; otherwise clear pidfile and launch cleanly.

# Terminal Activation v2 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the single-client, session-swapping activation model from `.claude/docs/terminal-activation-ux-spec.md`.

**Architecture:** Replace the multi-action-kind dispatch (Rust resolver picks between SwitchTmuxSession / EnsureTmuxSession / LaunchNewTerminal, Swift executor dispatches) with a unified Swift-side flow that always runs one algorithm: resolve managed TTY → switch session → focus terminal. The Rust resolver is retained for telemetry/logging but no longer drives action selection.

**Tech Stack:** Swift 6 / SwiftUI, tmux CLI, macOS Accessibility APIs (AXUIElement), Rust FFI (read-only)

**Design spec:** `.claude/docs/terminal-activation-ux-spec.md`

---

### Task 1: Add Managed-TTY State and Liveness Check

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- Test: `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`

**Context:** The spec requires managed-TTY affinity (B6). Currently TTY values are transient locals passed through method parameters. We need a stored property and a way to check if a TTY is still alive.

**Step 1: Write the failing test**

```swift
func testManagedClientTtyStartsNil() {
    let launcher = TerminalLauncher(
        resolveActivationDecisionOverride: { _ in fatalError() },
    )
    XCTAssertNil(launcher.managedClientTty)
}

func testIsTtyAliveReturnsFalseForNonexistentTty() async {
    let result = await TerminalLauncher.isTtyAlive("/dev/ttys99999")
    XCTAssertFalse(result)
}
```

**Step 2: Run test to verify it fails**

Run: `cd apps/swift && swift test --filter 'testManagedClientTty|testIsTtyAlive' 2>&1 | tail -5`
Expected: FAIL — `managedClientTty` property doesn't exist, `isTtyAlive` doesn't exist.

**Step 3: Write minimal implementation**

Add to `TerminalLauncher` stored properties (near line 270):

```swift
/// The TTY of the tmux client Capacitor is managing. Persists across card clicks.
/// Cleared when the TTY becomes stale (tab closed). See spec invariant B6.
private(set) var managedClientTty: String?
```

Add static helper:

```swift
/// Check if a TTY device is still alive (file exists at /dev path).
static func isTtyAlive(_ tty: String) -> Bool {
    FileManager.default.fileExists(atPath: tty)
}
```

**Step 4: Run tests to verify they pass**

Run: `cd apps/swift && swift test --filter 'testManagedClientTty|testIsTtyAlive' 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
git commit -m "feat(swift): add managed-TTY state and liveness check to TerminalLauncher"
```

---

### Task 2: Unified TTY Resolution

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- Test: `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`

**Context:** The spec decision tree step 1 is: managed TTY (if alive) → any attached tmux client → launch new. This is a new static method that test harnesses can call directly.

**Step 1: Write the failing test**

```swift
// S6: Managed TTY died, another client exists → adopt it
func testResolveManagedTtyFallsBackToAnyClientWhenManagedDead() async {
    var scriptLog: [String] = []
    let result = await TerminalLauncher.resolveTmuxClient(
        managedTty: "/dev/ttys99999", // dead
        isTtyAlive: { _ in false },
        resolveAnyClientTty: {
            scriptLog.append("resolveAnyClient")
            return "/dev/ttys042" // another client
        },
    )
    XCTAssertEqual(result, "/dev/ttys042")
    XCTAssertTrue(scriptLog.contains("resolveAnyClient"))
}

// Managed TTY alive → use it directly
func testResolveManagedTtyUsesManagedWhenAlive() async {
    let result = await TerminalLauncher.resolveTmuxClient(
        managedTty: "/dev/ttys001",
        isTtyAlive: { _ in true },
        resolveAnyClientTty: { XCTFail("should not be called"); return nil },
    )
    XCTAssertEqual(result, "/dev/ttys001")
}

// No managed TTY, no clients → nil (caller must launch)
func testResolveManagedTtyReturnsNilWhenNoClients() async {
    let result = await TerminalLauncher.resolveTmuxClient(
        managedTty: nil,
        isTtyAlive: { _ in false },
        resolveAnyClientTty: { nil },
    )
    XCTAssertNil(result)
}
```

**Step 2: Run test to verify it fails**

Run: `cd apps/swift && swift test --filter 'testResolveManagedTty' 2>&1 | tail -5`
Expected: FAIL — `resolveTmuxClient` doesn't exist.

**Step 3: Write minimal implementation**

```swift
/// Resolve which tmux client TTY to use for session switching.
/// Spec decision tree step 1: managed (alive) → any client → nil (must launch).
static func resolveTmuxClient(
    managedTty: String?,
    isTtyAlive: (String) -> Bool,
    resolveAnyClientTty: () async -> String?,
) async -> String? {
    if let managedTty, isTtyAlive(managedTty) {
        return managedTty
    }
    return await resolveAnyClientTty()
}
```

**Step 4: Run tests to verify they pass**

Run: `cd apps/swift && swift test --filter 'testResolveManagedTty' 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
git commit -m "feat(swift): add unified TTY resolution with managed-TTY affinity"
```

---

### Task 3: Unified Session Ensure + Switch

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- Test: `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`

**Context:** Spec decision tree step 2: create session if needed, then switch-client. This combines the create-on-demand (B3) and session-swap (B2) invariants into one testable static method.

**Step 1: Write the failing test**

```swift
// S3: Session exists → just switch
func testEnsureAndSwitchExistingSessionJustSwitches() async {
    var commands: [String] = []
    let ok = await TerminalLauncher.ensureSessionAndSwitch(
        sessionName: "my-project",
        projectPath: "/path/to/project",
        clientTty: "/dev/ttys001",
        runScript: { cmd in
            commands.append(cmd)
            if cmd.contains("switch-client") { return (0, nil) }
            return (0, nil)
        },
    )
    XCTAssertTrue(ok)
    XCTAssertTrue(commands.contains(where: { $0.contains("switch-client") && $0.contains("my-project") }))
}

// S4: Session doesn't exist → create then switch
func testEnsureAndSwitchCreatesSessionWhenMissing() async {
    var commands: [String] = []
    let ok = await TerminalLauncher.ensureSessionAndSwitch(
        sessionName: "new-project",
        projectPath: "/path/to/new",
        clientTty: "/dev/ttys001",
        runScript: { cmd in
            commands.append(cmd)
            if cmd.contains("switch-client") && !commands.contains(where: { $0.contains("new-session") }) {
                return (1, "session not found") // first switch fails
            }
            return (0, nil)
        },
    )
    XCTAssertTrue(ok)
    XCTAssertTrue(commands.contains(where: { $0.contains("new-session") && $0.contains("new-project") }))
}
```

**Step 2: Run test to verify it fails**

Run: `cd apps/swift && swift test --filter 'testEnsureAndSwitch' 2>&1 | tail -5`
Expected: FAIL — `ensureSessionAndSwitch` doesn't exist.

**Step 3: Write minimal implementation**

```swift
/// Ensure a tmux session exists and switch the given client to it.
/// Spec decision tree step 2: try switch → if fail, create session → retry switch.
static func ensureSessionAndSwitch(
    sessionName: String,
    projectPath: String,
    clientTty: String,
    runScript: (String) async -> (exitCode: Int32, output: String?),
) async -> Bool {
    let escaped = shellEscape(sessionName)
    let escapedTty = shellEscape(clientTty)
    let switchCmd = "tmux switch-client -c \(escapedTty) -t \(escaped) 2>&1"

    // Try switching directly (session may already exist).
    let first = await runScript(switchCmd)
    if first.exitCode == 0 { return true }

    // Session doesn't exist — create it, then retry.
    let escapedPath = shellEscape(projectPath)
    let createResult = await runScript("tmux new-session -d -s \(escaped) -c \(escapedPath) 2>&1")
    if createResult.exitCode != 0 { return false }

    let retry = await runScript(switchCmd)
    return retry.exitCode == 0
}
```

**Step 4: Run tests to verify they pass**

Run: `cd apps/swift && swift test --filter 'testEnsureAndSwitch' 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
git commit -m "feat(swift): add ensureSessionAndSwitch for create-on-demand session switching"
```

---

### Task 4: Unified Activation Entry Point

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- Test: `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`

**Context:** This is the top-level method that wires together Tasks 1-3 + terminal focus. It replaces the resolver → executor dispatch chain for the common path. This is the heart of the spec implementation.

**Step 1: Write the failing tests**

```swift
// S1: No Ghostty, no sessions → launch Ghostty + create + attach
func testActivateProjectSessionLaunchesWhenNoClientAndNoGhostty() async {
    var launched = false
    var managedTty: String?
    let harness = makeUnifiedActivationHarness(
        managedTty: nil,
        isTtyAlive: { _ in false },
        resolveAnyClientTty: { nil },
        isGhosttyRunning: { false },
        launchTerminalWithTmux: { session, path in
            launched = true
            return true
        },
        onManagedTtyUpdate: { managedTty = $0 },
    )
    let ok = await harness.activateProjectSession(
        sessionName: "my-project",
        projectPath: "/path",
    )
    XCTAssertTrue(ok)
    XCTAssertTrue(launched)
}

// S3: Managed TTY alive, session exists → switch + focus
func testActivateProjectSessionSwitchesOnManagedTty() async {
    var switchedTo: String?
    var ghosttyActivated = false
    let harness = makeUnifiedActivationHarness(
        managedTty: "/dev/ttys001",
        isTtyAlive: { _ in true },
        ensureAndSwitch: { session, _, _ in
            switchedTo = session
            return true
        },
        activateTerminal: { ghosttyActivated = true; return true },
    )
    let ok = await harness.activateProjectSession(
        sessionName: "other-project",
        projectPath: "/other",
    )
    XCTAssertTrue(ok)
    XCTAssertEqual(switchedTo, "other-project")
    XCTAssertTrue(ghosttyActivated)
}

// S6: Managed TTY dead, other client exists → adopt + switch
func testActivateProjectSessionAdoptsClientWhenManagedDead() async {
    var adoptedTty: String?
    let harness = makeUnifiedActivationHarness(
        managedTty: "/dev/ttys99999",
        isTtyAlive: { _ in false },
        resolveAnyClientTty: { "/dev/ttys042" },
        ensureAndSwitch: { _, _, tty in
            adoptedTty = tty
            return true
        },
        activateTerminal: { return true },
    )
    let ok = await harness.activateProjectSession(
        sessionName: "proj",
        projectPath: "/proj",
    )
    XCTAssertTrue(ok)
    XCTAssertEqual(adoptedTty, "/dev/ttys042")
}
```

**Step 2: Run test to verify it fails**

Run: `cd apps/swift && swift test --filter 'testActivateProjectSession' 2>&1 | tail -5`
Expected: FAIL — `activateProjectSession` and harness don't exist.

**Step 3: Write minimal implementation**

Create a new `static` method `performUnifiedActivation` that implements the full decision tree, and a corresponding instance method `activateProjectSession` that provides the real dependencies. The static method is what tests call via the harness pattern.

```swift
/// Unified activation flow per spec v2 decision tree.
/// 1. Resolve client (managed → any → launch)
/// 2. Ensure session + switch
/// 3. Focus terminal
static func performUnifiedActivation(
    sessionName: String,
    projectPath: String,
    managedTty: String?,
    isTtyAlive: (String) -> Bool,
    resolveAnyClientTty: () async -> String?,
    ensureAndSwitch: (String, String, String) async -> Bool,
    launchTerminalWithTmux: (String, String) -> Bool,
    activateTerminal: (String?, String, String?) async -> Bool,
    onManagedTtyUpdate: (String?) -> Void,
) async -> Bool {
    // Step 1: Resolve client
    let clientTty = await resolveTmuxClient(
        managedTty: managedTty,
        isTtyAlive: isTtyAlive,
        resolveAnyClientTty: resolveAnyClientTty,
    )

    guard let clientTty else {
        // No client available — launch terminal with tmux (creates client).
        let launched = launchTerminalWithTmux(sessionName, projectPath)
        // TTY will be captured on next activation cycle after launch completes.
        return launched
    }

    // Update managed TTY if we adopted a new one.
    if clientTty != managedTty {
        onManagedTtyUpdate(clientTty)
    }

    // Step 2: Ensure session exists + switch client to it.
    let switched = await ensureAndSwitch(sessionName, projectPath, clientTty)
    guard switched else { return false }

    // Step 3: Focus terminal.
    _ = await activateTerminal(clientTty, projectPath, sessionName)
    return true
}
```

The instance method wires real dependencies. The test harness provides fakes.

**Step 4: Run tests to verify they pass**

Run: `cd apps/swift && swift test --filter 'testActivateProjectSession' 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
git commit -m "feat(swift): add unified activation entry point per spec v2 decision tree"
```

---

### Task 5: Wire Card Clicks to Unified Flow

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`

**Context:** Replace `launchTerminalWithAERSnapshot` → resolver → executor dispatch with a call to `activateProjectSession`. Keep the staleness guard and telemetry. Keep the Rust resolver call for logging/trace but don't use its action choice.

**Step 1: Modify `launchTerminalAsync`**

In `launchTerminalAsync` (line ~305), replace the resolver → executor chain with:

```swift
private func launchTerminalAsync(for project: Project, requestID: UInt64) async {
    guard shouldProcessLaunchRequest(requestID) else {
        debugLog("launchTerminalAsync ignored stale request id=\(requestID) path=\(project.path)")
        return
    }

    // Resolve tmux session name for this project.
    let sessionName = await resolveSessionName(for: project)

    // Log the Rust resolver's opinion for telemetry (but don't use its action).
    if let hudEngine {
        let trace = try? await resolveActivationDecision(for: project)
        if let trace { debugLog("rust_resolver_trace: \(trace)") }
    }

    guard shouldProcessLaunchRequest(requestID) else {
        debugLog("launchTerminalAsync stale after trace id=\(requestID)")
        return
    }

    // Run unified activation flow (spec v2).
    let success = await activateProjectSession(
        sessionName: sessionName,
        projectPath: project.path,
    )

    onActivationResult?(TerminalActivationResult(
        projectName: project.name,
        projectPath: project.path,
        success: success,
        usedFallback: false,
    ))
}
```

**Step 2: Run full test suite**

Run: `cd apps/swift && swift test 2>&1 | tail -5`
Expected: PASS (253 tests). Some existing tests may need updating if they mock the old resolver → executor path.

**Step 3: Commit**

```bash
git add apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
git commit -m "feat(swift): wire card clicks to unified activation flow"
```

---

### Task 6: Capture Managed TTY After Launch

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- Test: `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift`

**Context:** When we launch a new Ghostty tab with `tmux new -A -s`, we need to capture the resulting TTY as the managed TTY. The TTY isn't available synchronously (Ghostty needs time to start the shell), so we poll `tmux list-clients` after a brief delay.

**Step 1: Write the failing test**

```swift
func testManagedTtyCapturedAfterLaunch() async {
    // After launching, a poll should capture the new client TTY
    var capturedTty: String?
    let harness = makeUnifiedActivationHarness(
        managedTty: nil,
        isTtyAlive: { _ in false },
        resolveAnyClientTty: { nil }, // no clients initially
        launchTerminalWithTmux: { _, _ in true },
        pollForNewClient: { "/dev/ttys050" }, // client appears after launch
        onManagedTtyUpdate: { capturedTty = $0 },
    )
    let ok = await harness.activateProjectSession(
        sessionName: "fresh",
        projectPath: "/fresh",
    )
    XCTAssertTrue(ok)
    XCTAssertEqual(capturedTty, "/dev/ttys050")
}
```

**Step 2: Run test to verify it fails**

Run: `cd apps/swift && swift test --filter 'testManagedTtyCaptured' 2>&1 | tail -5`

**Step 3: Add post-launch TTY polling**

After `launchTerminalWithTmux` succeeds in `performUnifiedActivation`, poll for the new client:

```swift
guard let clientTty else {
    let launched = launchTerminalWithTmux(sessionName, projectPath)
    if launched, let newTty = await pollForNewClient() {
        onManagedTtyUpdate(newTty)
    }
    return launched
}
```

The real `pollForNewClient` implementation retries `tmux list-clients -F '#{client_tty}'` up to 10 times with 200ms delays, returning the first client TTY that appears.

**Step 4: Run tests to verify they pass**

Run: `cd apps/swift && swift test --filter 'testManagedTtyCaptured' 2>&1 | tail -5`
Expected: PASS

**Step 5: Commit**

```bash
git add apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
git commit -m "feat(swift): capture managed TTY after initial terminal launch"
```

---

### Task 7: Rebuild, Manual Smoke Test, and Push

**Step 1: Run full test suites**

```bash
cd /Users/petepetrash/Code/capacitor
cargo test
cd apps/swift && swift test
```
Expected: All tests pass.

**Step 2: Rebuild and relaunch**

```bash
cd /Users/petepetrash/Code/capacitor
./scripts/dev/restart-alpha-stable.sh
```

**Step 3: Manual smoke test**

Verify against spec scenario matrix:
- S1: Quit Ghostty. Kill all tmux sessions. Click a project card. Ghostty should launch with tmux attached.
- S3: With Ghostty open on one project's session, click a different project card. The tab should switch sessions (no new tab/window).
- S5: Click the same project again. Should be a no-op focus (no flicker).
- S6: Close the Ghostty tab. Click a project card. A new tab should appear.

**Step 4: Push**

```bash
git push
```

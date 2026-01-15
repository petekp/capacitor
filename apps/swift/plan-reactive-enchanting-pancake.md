# Active Project Indicator Implementation Plan

## Overview

Add a visual indicator (accent border highlight) to show which project card was last clicked/is currently focused in the terminal. Two implementation approaches explored:

- **Approach A: Click-Only Tracking** (Recommended Start) - Simple, ephemeral state tracking
- **Approach B: Live Terminal Tracking** (Optional Enhancement) - Sophisticated terminal/tmux detection

## User Requirements

- ✅ Ephemeral state (resets on app restart, no persistence)
- ✅ Visual style: Accent border highlight (2.5px solid orange border)
- ✅ Want to compare click-only vs. live terminal tracking approaches

## Recommended Implementation: Two-Phase Approach

### Phase 1: Click-Only Tracking (Ship First)

**Rationale:** Simple, reliable, zero overhead. Validates the feature's usefulness before investing in complexity.

**Implementation Effort:** 1-2 hours

#### Changes Required

**1. Add State to AppState**

File: `Sources/ClaudeHUD/Models/AppState.swift`

Add after line 51 (after `flashingProjects`):
```swift
// Active project tracking (ephemeral, click-based)
@Published var activeProjectPath: String?
```

Update `launchTerminal(for:)` at line 692:
```swift
func launchTerminal(for project: Project) {
    // Set active project when launching terminal
    activeProjectPath = project.path

    let process = Process()
    // ... existing code unchanged ...
}
```

**2. Pass Active State Through ProjectsView**

File: `Sources/ClaudeHUD/Views/Projects/ProjectsView.swift`

Update ProjectCardView initialization at line 61-92 (and line 123 for paused projects):
```swift
ProjectCardView(
    project: project,
    sessionState: appState.getSessionState(for: project),
    projectStatus: appState.getProjectStatus(for: project),
    flashState: appState.isFlashing(project),
    devServerPort: appState.getDevServerPort(for: project),
    isStale: isStale(project),
    todoStatus: appState.todosManager.getCompletionStatus(for: project.path),
    isActive: appState.activeProjectPath == project.path,  // NEW
    onTap: {
        appState.launchTerminal(for: project)
    },
    // ... rest unchanged ...
)
```

**3. Add Active Border to ProjectCardView**

File: `Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift`

Add parameter after line 17 (after `onRemove`):
```swift
let isActive: Bool  // NEW
```

Update `cardStyling` view modifier signature (line 357):
```swift
func cardStyling(
    isHovered: Bool,
    isReady: Bool,
    isActive: Bool,  // NEW parameter
    flashState: SessionState?,
    // ... rest unchanged
) -> some View {
```

Add active border overlay after flash overlay (around line 380):
```swift
.overlay {
    // Active project border
    if isActive {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(
                Color.hudAccent,
                lineWidth: 2.5
            )
            .transition(.opacity.animation(.easeOut(duration: 0.2)))
    }
}
```

Update call site at line 64:
```swift
.cardStyling(
    isHovered: isHovered,
    isReady: isReady,
    isActive: isActive,  // NEW
    flashState: flashState,
    // ... rest unchanged
)
```

#### Visual Design

- **Border:** 2.5px solid `Color.hudAccent` (orange)
- **Layer Order:** Active border sits above flash border, below ready glow
- **Animation:** `.easeOut(duration: 0.2)` transition
- **Behavior:** Border transfers to newly clicked card immediately

#### Trade-offs

✅ Pros:
- Simple implementation (~25 new lines)
- Zero runtime overhead
- Reliable, no external dependencies
- Immediate visual feedback
- Works with all terminal types

❌ Cons:
- Doesn't reflect actual terminal focus
- Border stays even after terminal closed
- Can't detect manual terminal switches

---

### Phase 2: Live Terminal Tracking (Optional Enhancement)

**Rationale:** Only implement if Phase 1 users request "live tracking" in feedback. Requires tmux.

**Implementation Effort:** 4-6 hours

#### Architecture

Create `TerminalTracker` actor that:
1. Polls macOS frontmost application (500ms interval)
2. Queries tmux for active session name
3. Maps session name → project path
4. Updates `activeProjectPath` in AppState

#### New Components

**1. Terminal Tracker Service**

File: `Sources/ClaudeHUD/Utils/TerminalTracker.swift` (NEW FILE)

```swift
import AppKit
import Foundation

actor TerminalTracker {
    private var activeProjectPath: String?
    private var pollingTask: Task<Void, Never>?
    private var projectsByName: [String: String] = [:]

    private let terminalApps: [String: String] = [
        "Ghostty": "com.mitchellh.ghostty",
        "iTerm2": "com.googlecode.iterm2",
        "Terminal": "com.apple.Terminal",
        "Alacritty": "org.alacritty",
        "kitty": "net.kovidgoyal.kitty",
        "WarpTerminal": "dev.warp.Warp-Stable"
    ]

    func startTracking(projects: [Project]) { /* polling loop */ }
    func stopTracking() { /* cancel task */ }
    func getActiveProjectPath() -> String? { /* return state */ }

    private func detectActiveProject() async {
        // 1. Check frontmost app is terminal
        // 2. Query tmux for active session
        // 3. Map session name to project path
    }

    private func getTmuxActiveSession() async -> String? {
        // Execute: tmux display-message -p '#{session_name}'
    }
}
```

**2. AppState Integration**

File: `Sources/ClaudeHUD/Models/AppState.swift`

Add after line 83:
```swift
private let terminalTracker = TerminalTracker()
private var trackerUpdateTask: Task<Void, Never>?
```

Update `init()` to start tracking:
```swift
Task {
    await terminalTracker.startTracking(projects: projects)
    startTrackerPolling()
}
```

Add polling method:
```swift
private func startTrackerPolling() {
    trackerUpdateTask = Task { @MainActor in
        while !Task.isCancelled {
            if let path = await terminalTracker.getActiveProjectPath() {
                activeProjectPath = path
            } else {
                activeProjectPath = nil
            }
            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }
    }
}
```

#### Performance

- **Polling:** 500ms interval (2 Hz)
- **CPU:** < 1% on modern Macs
- **Battery:** Negligible impact
- **Actor isolation:** Prevents UI blocking

#### Trade-offs

✅ Pros:
- True ground truth (reflects actual focus)
- Updates automatically with terminal switches
- Indicator disappears when terminal closes
- Works with manual tmux sessions

❌ Cons:
- Complex implementation (~200 new lines)
- 500ms polling overhead
- Requires tmux for detection
- More surface area for bugs
- Terminal app detection can be brittle

#### Edge Cases

- **No tmux:** Gracefully degrades (no indicator shown)
- **Unknown terminal:** Falls back to no indicator
- **Multiple terminals:** Tracks frontmost only
- **Session name collision:** Rare but possible incorrect mapping

---

## Critical Files

### Phase 1 (Click-Only)
1. `Sources/ClaudeHUD/Models/AppState.swift` - Add state, update launchTerminal()
2. `Sources/ClaudeHUD/Views/Projects/ProjectsView.swift` - Pass isActive prop
3. `Sources/ClaudeHUD/Views/Projects/ProjectCardView.swift` - Add border overlay

### Phase 2 (Live Tracking - If Pursued)
4. `Sources/ClaudeHUD/Utils/TerminalTracker.swift` - NEW FILE for detection
5. `Sources/ClaudeHUD/Models/AppState.swift` - Integrate tracker polling

---

## Verification Plan

### Phase 1 Testing

1. **Build and run:** `swift build && swift run`
2. **Click project card:** Verify orange border appears
3. **Click different card:** Verify border moves to new card
4. **Restart app:** Verify border resets (ephemeral state works)
5. **Test with ready glow:** Verify layers don't conflict (border should be visible below glow)
6. **Test hover states:** Verify border doesn't interfere with hover animations
7. **Test flash states:** Verify active border and flash border can coexist

### Phase 2 Testing (If Implemented)

8. **Terminal focus:** Open terminal for project, verify border appears
9. **Switch terminals:** Focus different terminal, verify border updates
10. **Close terminal:** Close terminal window, verify border disappears
11. **No tmux:** Disable tmux, verify app doesn't crash (graceful degradation)
12. **Multiple projects:** Open terminals for 3 projects, switch between them, verify indicator follows focus
13. **Performance:** Monitor CPU usage with Activity Monitor (should be < 1%)

---

## Recommendation

**Ship Phase 1 first.** It solves 90% of the use case with 10% of the complexity. Only implement Phase 2 if users specifically request live terminal tracking in feedback.

**Future Enhancement:** Could add Settings toggle for "Click tracking" vs "Live terminal tracking" modes if both are valuable.

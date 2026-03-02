# Terminal Emulator Interaction Paradigms on macOS

**Research Date:** 2026-03-01
**Context:** Capacitor needs to detect terminal apps, find tabs/windows for specific sessions, focus/activate terminals, open new tabs with commands, and map TTYs to terminal windows.

---

## Current Capacitor Approach (Baseline)

Capacitor currently uses a layered strategy combining multiple paradigms:

1. **Accessibility APIs** for Ghostty window/tab discovery and focus (`GhosttyAXReader.swift`)
2. **AppleScript** for iTerm2 and Terminal.app TTY-based tab selection and TTY discovery
3. **tmux CLI** for session management, client resolution, and pane-level routing
4. **NSWorkspace/NSRunningApplication** for detecting running terminal apps
5. **Process inspection** to resolve PIDs to apps

The activation decision tree (in `TerminalLauncher.swift`) is:
1. Check shell hook snapshot for active shell → resolve terminal from TTY
2. Query tmux for session at project path → switch client
3. Fall back to launching new terminal with tmux session

---

## Paradigm 1: Accessibility APIs (AXUIElement)

### How It Works

The macOS Accessibility framework (`AXUIElement`) provides a tree-structured view of any application's UI hierarchy. For terminal emulators:

- `AXUIElementCreateApplication(pid)` creates a handle to the app
- `kAXWindowsAttribute` enumerates top-level windows
- `kAXTabsAttribute` or `kAXChildrenAttribute` → `AXTabGroup` → `kAXTabsAttribute` reads tabs
- `kAXTitleAttribute` reads the current title of tabs/windows
- `kAXSelectedAttribute` / `kAXValueAttribute` reads selection state
- `AXUIElementPerformAction(kAXPressAction)` activates tabs
- `AXUIElementPerformAction(kAXRaiseAction)` raises windows

### Capacitor's Implementation

`DefaultGhosttyAXReader` (444 lines) implements a complete Ghostty-specific AX reader:

```swift
// Read Ghostty's window/tab state
let appElement = AXUIElementCreateApplication(ghosttyApp.processIdentifier)
var windowsRef: CFTypeRef?
AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
```

Tab matching uses a sophisticated ranking system based on:
- Path matching (exact > prefix > suffix with 2+ component overlap)
- tmux session name matching (from tab title decorations)
- Session hint matching (authoritative, rank 3)
- Tiebreakers: selected tab > main window > lowest index

### What Can Be Read From Different Terminals

| Terminal     | Windows | Tabs | Tab Titles | Selection | Tab Actions | Notes |
|-------------|---------|------|------------|-----------|-------------|-------|
| Ghostty     | Yes     | Yes  | Yes        | Yes       | Press/Raise | Requires AXTabGroup traversal |
| iTerm2      | Yes     | Yes  | Yes        | Yes       | Press/Raise | Also has AppleScript dictionary |
| Terminal.app| Yes     | Yes  | Yes        | Yes       | Press/Raise | Also has AppleScript dictionary |
| Alacritty   | Yes     | N/A  | Yes        | N/A       | Raise only  | Single-window, no tabs |
| kitty       | Yes     | Partial| Yes      | Partial   | Varies      | Tab structure varies by layout |
| Warp        | Yes     | Limited| Yes      | Limited   | Varies      | Non-standard UI elements |

### Limitations and Failure Modes

1. **TCC Permissions (Critical):** App must be granted Accessibility permission in System Preferences > Privacy & Security > Accessibility. Without it, all AX calls return `kAXErrorAPIDisabled`. The user must manually grant this through a dialog requiring admin authentication. There is no programmatic way to grant this.

2. **Async Title Updates:** After a `tmux switch-client`, the title propagation chain is: tmux escape sequence -> terminal processes it -> renders -> AX tree updates. This can take 500ms-1s. Capacitor handles this with a retry loop (15 retries x 200ms = 3 second window).

3. **AX Tree Structure Varies by App:** Ghostty uses `AXTabGroup` as an intermediate container, requiring a two-level traversal. Other terminals may expose tabs directly under `kAXTabsAttribute`.

4. **Tab Title Content Is Unreliable:** Tab titles depend on what the shell or tmux is configured to emit. They may contain:
   - Full paths (`/Users/pete/Code/capacitor`)
   - Tilde paths (`~/Code/capacitor`)
   - Ellipsized paths (`...Code/capacitor`)
   - tmux session decorations (`session:1:zsh - "Window Title"`)
   - Emoji decorations
   - Completely custom text

5. **Performance:** Each `AXUIElementCopyAttributeValue` call is a synchronous IPC to the target application. For an app with N windows and M tabs per window, you're making O(N * M) IPC calls. This is fast enough for typical setups (< 10 windows) but becomes noticeable with many windows. AX calls can block the main thread.

6. **No TTY Information:** AX provides no way to discover which TTY device is associated with a tab. You can only match by title or position.

7. **Sandboxed Apps:** Sandboxed apps cannot use the Accessibility API at all unless they have the `com.apple.security.automation.apple-events` entitlement.

### Real-World Users

- **Capacitor** (this project) - Ghostty tab matching
- **Hammerspoon** - General window management
- **Rectangle / Magnet** - Window tiling
- **Fig (now AWS Q Developer)** - Terminal augmentation (used AX for window events)
- **yabai** - Tiling window manager

### Reliability Assessment

Medium. Works well when permissions are granted and the target app has a standard AX tree, but the asynchronous nature of title updates and the variability of tab title content make it inherently fuzzy. Best used as a "last mile" focus mechanism after session state is established through other means.

---

## Paradigm 2: AppleScript / JXA

### Scriptable Terminal Dictionaries

| Terminal     | Has sdef | TTY Access | Tab Selection | Window Creation | Command Execution | Notes |
|-------------|----------|------------|---------------|-----------------|-------------------|-------|
| Terminal.app| Yes      | `tty of tab` | `set selected tab` | `do script` | `do script "cmd"` | Most complete |
| iTerm2      | Yes      | `tty of session` | `select tab/session` | `create window/tab` | `write text` | Two APIs (AppleScript + Python) |
| Ghostty     | **No** (WIP) | Planned | Planned | Partial (`open -na`) | Via System Events | App Intents being wrapped |
| Alacritty   | No       | N/A | N/A | N/A | N/A | No scripting support |
| kitty       | No       | N/A | N/A | N/A | N/A | Uses own remote protocol |
| Warp        | No       | N/A | N/A | N/A | N/A | No scripting API |

### Terminal.app

Full AppleScript dictionary with TTY access:

```applescript
tell application "Terminal"
    repeat with w in windows
        repeat with t in tabs of w
            if tty of t is "/dev/ttys005" then
                set selected tab of w to t
                set frontmost of w to true
            end if
        end repeat
    end repeat
end tell
```

Terminal.app's `do script` command is the simplest way to run a command in a new window/tab.

### iTerm2

Two scripting APIs:

**AppleScript** (legacy but still functional):
```applescript
tell application "iTerm"
    create window with default profile command "tmux new-session -A -s myproject"
    repeat with w in windows
        repeat with t in tabs of w
            repeat with s in sessions of t
                if tty of s is "/dev/ttys005" then
                    select t
                    select s
                    set index of w to 1
                end if
            end repeat
        end repeat
    end repeat
end tell
```

**Python API** (modern, more capable):
- Must be enabled in Preferences > Magic > Enable Python API
- Provides async event-driven control
- Can create custom UI elements, monitor output, set session titles
- Scripts stored in `~/Library/ApplicationSupport/iTerm2/Scripts/`
- More powerful but requires Python runtime and user opt-in
- Supports finding panes by process, custom context menus, broadcast domains

### Ghostty

Currently has **no AppleScript dictionary**. Active development on two fronts:

1. **App Intents wrapping** (Discussion [#10201](https://github.com/ghostty-org/ghostty/discussions/10201)): Community-developed AppleScript bindings that wrap Ghostty's existing App Intents. Exposes:
   - Terminal objects with properties: index, UUID, title, working directory
   - Commands: `new terminal`, `send text`, `focus`, `close`, `split direction`
   - `perform action` for keybind handlers
   - Status: functional prototype, not yet merged upstream

2. **Platform-native IPC** (Discussion [#2353](https://github.com/ghostty-org/ghostty/discussions/2353)): Mitchell Hashimoto's preferred approach: "platform-specific IPC capabilities, such as AppleScript on macOS, D-Bus on Linux."

**Current workarounds for Ghostty:**
- `open -na "Ghostty.app" --args -e sh -c "command"` (but `-e` replaces shell, skipping rc files)
- `open -na "Ghostty.app" --args --working-directory="/path"` (open new window at path)
- System Events keystroke injection for new tabs: `keystroke "t" using command down`
- Clipboard paste via System Events (avoids CJK input method garbling)
- Capacitor uses the clipboard paste approach through osascript for tab creation

### Performance Characteristics

AppleScript execution via `osascript` spawns a subprocess, which adds ~50-100ms overhead per invocation. For TTY-based tab discovery that iterates over all windows/tabs, this can take 200-500ms depending on the number of open sessions. The Python API for iTerm2 avoids this subprocess overhead but requires a persistent connection.

### Limitations

1. **Ghostty and Warp have no dictionaries** - the two fastest-growing terminals are unscriptable
2. **osascript subprocess overhead** - each call is ~50-100ms minimum
3. **Script injection risk** - user-controlled values (paths, session names) must be carefully escaped for AppleScript string interpolation. Capacitor uses `shellEscape()` and `bashDoubleQuoteEscape()` for this.
4. **App must be running** - AppleScript `tell application` will launch the app if not running, which may be undesirable
5. **No standard operations** - each terminal's dictionary uses different terminology

### Reliability Assessment

High for Terminal.app and iTerm2. Non-existent for Ghostty, Warp, and Alacritty. The TTY-based tab lookup in Terminal.app and iTerm2 is the most reliable way to focus a specific terminal session because TTYs are unique identifiers, unlike tab titles which are mutable.

---

## Paradigm 3: Terminal-Specific APIs/Protocols

### iTerm2 Python API

The most capable terminal-specific API available:

- **Transport:** WebSocket connection to iTerm2's built-in server
- **Authentication:** User must enable in preferences; security dialog on connection
- **Capabilities:** Full control over windows, tabs, sessions, profiles, menus, status bar
- **Async events:** Can subscribe to session creation/termination, focus changes, output
- **Custom UI:** Can add custom status bar components and context menu items
- **TTY access:** Can query `tty` property of any session

**Limitation:** Only works with iTerm2. Requires Python runtime. User must opt-in.

### kitty Remote Control Protocol

A JSON-over-escape-sequence protocol:

```
<ESC>P@kitty-cmd{"cmd":"ls","version":[0,35,0]}<ESC>\
```

**Transport methods:**
1. Terminal stream (stdin) - requires `allow_remote_control=yes` in config
2. Unix socket (`--listen-on unix:/path`) - preferred for external control
3. Environment variable `KITTY_WINDOW_ID` for targeting specific windows

**Security:** As of v0.26.0, supports encrypted communication via ECDH X25519 + AES-256-GCM.

**Key commands for our use case:**
- `ls` - List all OS windows, tabs, and windows with IDs, titles, dimensions, environment
- `focus-window --match pid:<pid>` - Focus by PID (Capacitor already uses this)
- `focus-tab` - Focus specific tab
- `launch` - Create new windows/tabs
- `send-text` - Send text to specific windows
- `action` - Execute configured actions

**CLI tool:** `kitten @ <command>` provides user-friendly access.

**Limitation:** User must enable remote control in config. macOS requires workaround via `~/Library/Application Support/kitty/macos-launch-services-cmdline` for GUI-launched instances.

### Ghostty IPC (In Development)

Current status:
- **macOS:** No stable IPC yet. App Intents exist but no CLI/AppleScript bindings shipped
- **Linux:** D-Bus integration for `ghostty +new-window` and `ghostty +list-actions`
- **Planned:** AppleScript dictionary wrapping all App Intents
- **`ghostty +list-actions`** is available but only lists; cannot invoke actions programmatically on macOS

### Warp API

Warp has pivoted heavily toward their cloud platform:
- **`oz` CLI** (replaces deprecated `warp-cli`) - for cloud agent management, not local terminal control
- **REST API** - for task lifecycle on their cloud platform
- **No local scripting API** - no AppleScript dictionary, no IPC protocol
- Cannot programmatically create/focus tabs or windows
- Clipboard paste via System Events is the only workaround

### Terminal-Agnostic Protocols

There is no widely adopted terminal-agnostic control protocol. The closest candidates:
- **OSC escape sequences** - standardized (e.g., OSC 7 for CWD reporting, OSC 52 for clipboard) but read-only; cannot control window/tab state
- **Sixel/Kitty Graphics Protocol** - for image display, not control
- **tmux control mode** - only works within tmux sessions (see Paradigm 4)

### Reliability Assessment

Varies wildly. kitty's protocol is well-designed and reliable *if* the user enables it. iTerm2's Python API is excellent but iTerm2-only. Ghostty's is not yet available. No universal solution exists.

---

## Paradigm 4: tmux as the Universal Abstraction Layer

### Architecture

Instead of writing per-terminal integration code, use tmux as the sole coordination layer:

```
User clicks project in Capacitor
  -> Capacitor creates/switches tmux session via CLI
  -> Terminal renders the tmux session (any terminal works)
  -> Capacitor only needs to focus the terminal app (not a specific tab)
```

### Key tmux Commands for Programmatic Control

```bash
# Session management
tmux new-session -d -s <name> -c <path>    # Create detached session
tmux new-session -A -s <name>               # Attach-or-create
tmux switch-client -c <tty> -t <session>    # Switch specific client
tmux list-sessions -F '#{session_name}'     # List sessions

# Window/pane inspection
tmux list-windows -a -F '#{session_name}\t#{pane_current_path}'
tmux list-panes -t <session> -F '#{session_name}\t#{window_index}\t#{pane_index}\t#{pane_current_path}'

# Client management
tmux list-clients -F '#{client_tty}'        # Find attached clients
tmux display-message -p '#{client_tty}'     # Current client TTY
```

### tmux Control Mode (-CC)

A text-based protocol for deep integration:

- **How it works:** `tmux -CC attach` connects a client that receives structured text protocol instead of rendered output
- **Protocol:** Commands produce `%begin`/`%end` blocks. Async notifications prefixed with `%` (e.g., `%window-add`, `%session-changed`, `%output`)
- **iTerm2 native integration:** iTerm2 is the primary consumer of control mode. When attached via `-CC`, tmux windows become native iTerm2 tabs, tmux panes become native split panes
- **Capability:** Full bidirectional control - can send commands and receive real-time notifications about all state changes

**Control Mode Protocol:**
```
%begin 1234567890 1 0
<command output>
%end 1234567890 1 0

# Notifications
%window-add @1
%session-changed $2 new-session-name
%output %0 some terminal output with \134 escapes
```

### tmux Hooks and Events

tmux supports hooks for reacting to events:
```bash
tmux set-hook -g session-created 'run-shell "notify-capacitor session-created"'
tmux set-hook -g client-attached 'run-shell "notify-capacitor client-attached"'
tmux set-hook -g window-renamed 'run-shell "notify-capacitor window-renamed"'
```

### Capacitor's Current tmux Usage

Capacitor already heavily relies on tmux:
- `findTmuxSessionForPath()` - discovers existing sessions by path
- `bestTmuxSessionForPath()` - ranks sessions by path overlap
- `ensureSessionAndSwitch()` - create-if-missing + switch-client
- `resolveAnyTmuxClientTty()` - find any attached client's TTY
- `pollForTmuxClient()` - retry loop waiting for new client after launch
- `focusTmuxPaneForProjectPathIfAvailable()` - focus specific pane within session
- `bestTmuxPaneTargetForProjectPath()` - rank panes by path match

### Limitations of tmux-Only Approach

1. **Requires tmux** - Users who don't use tmux are excluded. Some developers actively dislike tmux.
2. **No direct tab focus** - tmux can switch sessions, but the terminal still needs to be focused/raised. This is the "last mile" problem.
3. **Client TTY resolution** - When Capacitor runs outside a tmux session (it's a SwiftUI app), `tmux display-message` can't resolve `#{client_tty}`. Must fall back to `list-clients`.
4. **Launch delay** - After launching a new terminal with `tmux new-session -A`, there's a multi-second window where no client is attached yet (shell init, tmux connect). Capacitor polls for up to 10 seconds.
5. **Title propagation delay** - After `switch-client`, tmux sends escape sequences to update the terminal's title, but this propagation has measurable latency (500ms-1s).
6. **Single client per TTY** - A tmux client is bound to one TTY. If the user has multiple terminal windows, you need to know *which* one is the tmux client to focus the right one.
7. **No window geometry control** - tmux cannot move, resize, or tile the host terminal's windows.

### Reliability Assessment

High for session management. The tmux CLI is stable, well-documented, and its behavior is predictable. But tmux alone cannot solve the "focus the right terminal window" problem - it needs to be paired with at least one of the other paradigms for the UI-level activation.

---

## Paradigm 5: Process/System-Level Inspection

### NSWorkspace / NSRunningApplication

```swift
// Detect running terminals
let ghostty = NSWorkspace.shared.runningApplications.first {
    $0.bundleIdentifier == "com.mitchellh.ghostty"
}

// Activate app
ghostty?.activate()

// Check frontmost
NSWorkspace.shared.frontmostApplication
```

**Capabilities:**
- Enumerate all running applications
- Get PID, bundle identifier, localized name
- Activate/hide/unhide applications
- No window-level or tab-level control
- No TTY information

### CGWindowListCopyWindowInfo

```swift
let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]]
// Returns: kCGWindowOwnerPID, kCGWindowName, kCGWindowBounds, kCGWindowLayer, etc.
```

**Capabilities:**
- Enumerate all on-screen windows with bounds, owner PID, window name
- Front-to-back ordering (when using `optionOnScreenOnly`)
- Window name is available (requires Screen Recording permission since macOS 10.15)
- Cannot distinguish tabs within a single window
- Cannot focus/raise specific windows (read-only)

**Limitations:**
- `kCGWindowName` requires **Screen Recording** TCC permission (separate from Accessibility)
- No tab-level information
- Read-only - cannot perform actions on windows
- Only shows windows in current space

### PID-to-TTY Mapping via lsof/ps

```bash
# Find TTY devices for a process
lsof -p <pid> | grep /dev/ttys

# Find process owning a TTY
lsof /dev/ttys005

# ps shows TTY column
ps -eaf | grep <pid>
```

**The mapping chain:**
1. Shell process (e.g., zsh) → owns `/dev/ttysNNN`
2. Shell is a child of terminal emulator process
3. Terminal emulator process → has PID → matches `NSRunningApplication`

**Practical use:** Given a TTY from tmux (`#{client_tty}`), you can trace up the process tree to find the owning terminal application:

```bash
# Get PID that owns a TTY
lsof -t /dev/ttys005
# -> returns PID of the shell

# Get parent PID
ps -o ppid= -p <shell_pid>
# -> returns PID of the terminal emulator

# Match to NSRunningApplication by PID
```

### sysctl for Process Info

```swift
var info = kinfo_proc()
var size = MemoryLayout<kinfo_proc>.size
var mib = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
sysctl(&mib, 4, &info, &size, nil, 0)
// info.kp_eproc.e_tdev contains TTY device number
```

**Note:** This is lower-level than `lsof` but avoids spawning a subprocess. Can be used to efficiently map PIDs to TTY device numbers.

### Capacitor's Current Usage

- `NSWorkspace.shared.runningApplications` for detecting which terminals are running
- `NSRunningApplication.activate()` for app-level activation (with AppleScript fallback)
- `isTerminalApp()` matching by localized name
- Does **not** currently use CGWindowListCopyWindowInfo or lsof for TTY discovery

### TTY Discovery Flow (Current)

Capacitor's `discoverTerminalOwningTTY()` method does NOT use process inspection. Instead, it queries iTerm2 and Terminal.app via AppleScript to check if they own a given TTY:

```swift
private func discoverTerminalOwningTTY(tty: String) async -> ParentApp? {
    if findRunningApp(.iTerm) != nil, await queryITermForTTY(tty) { return .iTerm }
    if findRunningApp(.terminal) != nil, await queryTerminalAppForTTY(tty) { return .terminal }
    return nil
}
```

This is limited to terminals with AppleScript TTY access. A process-inspection approach could work for any terminal.

### Reliability Assessment

High for detection, low for control. Process inspection is reliable for answering "what terminal owns this TTY?" but provides no mechanism for tab-level focus. Best used as input to other paradigms (e.g., once you know it's Ghostty, use AX; once you know it's iTerm, use AppleScript).

---

## Paradigm 6: Custom Terminal Integration

### SwiftTerm (Embeddable Terminal)

[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza provides:

- **`TerminalView`** - NSView (macOS) / UIView (iOS) for embedding
- **`LocalProcessTerminalView`** - connects to a local PTY with a shell process
- **VT100/Xterm emulation** - full Unicode, grapheme clusters, sixel graphics
- **PTY allocation** - handles pseudo-terminal lifecycle
- **Commercial users:** Secure Shellfish, La Terminal, CodeEdit

**Integration model:**
```swift
let terminalView = LocalProcessTerminalView(frame: .zero)
terminalView.startProcess(executable: "/bin/zsh", args: [], environment: env)
addSubview(terminalView)
```

### Libghostty (Future)

[Libghostty](https://mitchellh.com/writing/libghostty-is-coming) is Ghostty's embeddable library strategy:

- **libghostty-vt** (first component, in development): VT parsing + state management
  - Zero dependencies (not even libc)
  - SIMD-optimized parsing
  - Zig API available for testing; C API coming soon
  - Target: tagged release within ~6 months of announcement
- **Future components:** Input handling, GPU rendering (Metal/OpenGL), framework widgets (GTK, Swift)

**Relevance to Capacitor:** If libghostty ships Swift/SwiftUI widgets, Capacitor could embed terminal views directly rather than coordinating with external terminal apps.

### Direct PTY Allocation

For maximum control, allocate PTYs directly:

```swift
import Darwin

var master: Int32 = 0
var slave: Int32 = 0
openpty(&master, &slave, nil, nil, nil)

let process = Process()
process.executableURL = URL(fileURLWithPath: "/bin/zsh")
process.standardInput = FileHandle(fileDescriptor: slave)
process.standardOutput = FileHandle(fileDescriptor: slave)
process.standardError = FileHandle(fileDescriptor: slave)
process.launch()
```

### Advantages of Embedding

1. **Full control** - You own the terminal, no IPC/permissions needed
2. **Consistent UX** - No dependence on user's terminal choice
3. **Session management built-in** - Can manage tabs, splits, history natively
4. **TTY ownership** - You know exactly which TTY belongs to which view

### Disadvantages of Embedding

1. **Massive scope increase** - Building/maintaining a terminal emulator is a significant undertaking
2. **User preference** - Developers have strong terminal preferences (keybindings, themes, extensions)
3. **Duplication** - Users would have both their preferred terminal AND Capacitor's embedded terminal
4. **Performance** - GPU-accelerated rendering (what Ghostty/kitty do) is hard to replicate
5. **Ecosystem gap** - No tmux integration, no shell history sharing, no terminal-specific plugins

### Reliability Assessment

Highest possible control and reliability, but at enormous cost. Only makes sense if Capacitor wants to become a terminal application rather than a terminal coordinator.

---

## Comparative Analysis

### Capability Matrix

| Capability | AX API | AppleScript | Terminal APIs | tmux | Process Inspect | Embedded |
|-----------|--------|-------------|---------------|------|----------------|----------|
| Detect running terminals | No | No | No | No | **Yes** | N/A |
| Find tab by TTY | No | **iTerm/Terminal only** | **kitty** | **Indirect** | **Via PID chain** | **Yes** |
| Find tab by path/title | **Yes** | **iTerm/Terminal** | **kitty** | **Yes** | No | **Yes** |
| Focus specific tab | **Yes** | **iTerm/Terminal** | **kitty** | No (session only) | No | **Yes** |
| Focus window | **Yes** | **Yes** | **kitty** | No | No | **Yes** |
| Open new tab | No | **iTerm/Terminal** | **kitty** | **Via terminal** | No | **Yes** |
| Run command in tab | No | **iTerm/Terminal** | **kitty** | **Yes** | No | **Yes** |
| Works with Ghostty | **Yes** | **WIP** | **Not yet** | **Yes** | **Yes** | N/A |
| Works with Warp | Limited | No | No | Limited | **Yes** | N/A |
| No special permissions | No (needs AX) | No (needs Automation) | Varies | **Yes** | Mostly | **Yes** |

### Permission Requirements

| Paradigm | TCC Permission | User Action Required |
|----------|---------------|---------------------|
| AX APIs | Accessibility | System Preferences toggle + admin auth |
| AppleScript | Automation (per-app) | Allow dialog on first use |
| CGWindowList names | Screen Recording | System Preferences toggle |
| Terminal APIs | Varies | kitty: config file edit; iTerm2: preference toggle |
| tmux | None | tmux must be installed |
| Process inspection | None | None |
| Embedded | None | None |

### Reliability Ranking (for Capacitor's use case)

1. **tmux CLI** - Most reliable for session management, works universally
2. **AppleScript TTY lookup** - Most reliable for tab focus (iTerm2/Terminal.app only)
3. **AX API** - Reliable for Ghostty tab focus after session switch
4. **Process inspection** - Reliable for detection, not actionable alone
5. **Terminal-specific APIs** - Reliable per-terminal but fragmented
6. **Embedded terminal** - Maximum reliability but wrong scope

---

## Recommendations for Capacitor

### Current Architecture Assessment

The current layered approach is sound. The key insight is that **no single paradigm works for all terminals**, so the strategy of:

1. tmux for session state (universal)
2. Per-terminal activation for UI focus (varies)
3. AX as the Ghostty-specific "last mile"
4. AppleScript for iTerm2/Terminal.app "last mile"
5. NSWorkspace as the fallback

...is the correct architecture. The layers compose rather than compete.

### Gap Analysis

1. **Ghostty AppleScript** - When the App Intents wrapping ships, Capacitor should adopt it. It would provide TTY-equivalent tab targeting (via UUID) that AX title matching can't achieve.

2. **TTY discovery via process inspection** - The current `discoverTerminalOwningTTY()` only checks iTerm2 and Terminal.app via AppleScript. A process-tree-based approach (PID chain from TTY -> shell -> terminal) would work for *any* terminal without requiring AppleScript support.

3. **kitty remote control** - If kitty users become a meaningful segment, `kitten @ focus-window --match pid:<pid>` is already used but could be expanded.

4. **tmux control mode** - Currently unused. Could replace the polling-based client discovery with event-driven notifications. However, maintaining a persistent `-CC` connection adds complexity.

### Watch List

- **Ghostty AppleScript/App Intents**: Track [Discussion #10201](https://github.com/ghostty-org/ghostty/discussions/10201) and [Discussion #2353](https://github.com/ghostty-org/ghostty/discussions/2353)
- **Libghostty Swift framework**: If libghostty ships Swift widgets, it could enable a hybrid model where Capacitor embeds terminal views for agent output while coordinating with the user's main terminal
- **Warp local API**: Currently non-existent. Warp's focus is on cloud agents, not local scriptability
- **Terminal-agnostic protocols**: No movement here; the fragmentation is likely permanent

---

## Sources

### Ghostty
- [Scripting API for Ghostty - Discussion #2353](https://github.com/ghostty-org/ghostty/discussions/2353)
- [macOS: AppleScript interface for Ghostty - Discussion #10201](https://github.com/ghostty-org/ghostty/discussions/10201)
- [Libghostty Is Coming - Mitchell Hashimoto](https://mitchellh.com/writing/libghostty-is-coming)
- [Ghostty Terminal API (VT) Reference](https://ghostty.org/docs/vt/reference)
- [Automating 4 macOS Terminals for Claude Code](https://dev.to/thinkerjack/automating-4-macos-terminals-for-claude-code-applescript-ghosttys-e-trap-and-warps-missing-3nk1)

### iTerm2
- [iTerm2 Python API Documentation](https://iterm2.com/python-api/)
- [iTerm2 Scripting Fundamentals](https://iterm2.com/documentation-scripting-fundamentals.html)
- [iTerm2 tmux Integration](https://iterm2.com/documentation-tmux-integration.html)

### kitty
- [kitty Remote Control Protocol](https://sw.kovidgoyal.net/kitty/rc_protocol/)
- [kitty Terminal Protocol Extensions](https://sw.kovidgoyal.net/kitty/protocol-extensions/)

### tmux
- [tmux Control Mode Wiki](https://github.com/tmux/tmux/wiki/Control-Mode)
- [iTerm2 + tmux -CC: Remote Development Setup](https://evoleinik.com/posts/iterm2-tmux-control-mode/)

### SwiftTerm
- [SwiftTerm GitHub](https://github.com/migueldeicaza/SwiftTerm)

### macOS APIs
- [CGWindowListCopyWindowInfo - Apple Developer](https://developer.apple.com/documentation/coregraphics/1455137-cgwindowlistcopywindowinfo)
- [AXUIElement.h - Apple Developer](https://developer.apple.com/documentation/applicationservices/axuielement_h)
- [macOS TCC Permissions - Accessibility](https://jano.dev/apple/macos/swift/2025/01/08/Accessibility-Permission.html)

### Warp
- [Warp CLI + Scriptability Discussion #612](https://github.com/warpdotdev/Warp/discussions/612)
- [Warp Oz CLI Reference](https://docs.warp.dev/platform/cli)

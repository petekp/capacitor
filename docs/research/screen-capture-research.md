# Screen Capture & Recording Research for Checkpoint Artifacts

> Date: 2026-03-21
> Status: **SUPERSEDED** — This research was the input to an adversarial review that changed the architecture. The final architecture uses **agent-browser** (headless Chrome CLI) instead of ScreenCaptureKit, and renders Mermaid via agent-browser instead of WKWebView. See `.pipeline/phases/phase-002-align/artifacts/execution-spec.md` for the current spec.
> Original status: Research complete, pending adversarial review

## Executive Summary

Capacitor's checkpoint system can be extended with three types of media artifacts: **screenshots**, **screen recordings**, and **Mermaid diagrams**. The recommended approach uses ScreenCaptureKit (macOS 14+) for captures, extends the existing runtime service HTTP IPC, and renders Mermaid diagrams live in the review window.

---

## 1. Screen Capture API: ScreenCaptureKit

### Why ScreenCaptureKit over CGWindowListCreateImage

`CGWindowListCreateImage` was **deprecated in macOS 14 and obsoleted in macOS 15**. ScreenCaptureKit is the replacement, with dramatic performance improvements: OBS Project benchmarked 60 fps with 50% less CPU and 15% less RAM vs CGWindowListCreateImage's ~7 fps with visible stuttering.

### Key APIs

| API | Use Case | macOS Min |
|-----|----------|-----------|
| `SCScreenshotManager.captureImage()` | Single-frame screenshot → `CGImage` | 14.0 |
| `SCScreenshotManager.captureSampleBuffer()` | Single-frame → `CMSampleBuffer` | 14.0 |
| `SCStream` + `SCStreamOutput` | Continuous capture for recording | 12.3 |
| `SCRecordingOutput` | Built-in record-to-file | 15.0 |
| `SCShareableContent` | Window/display enumeration | 12.3 |

### Window Identification

```swift
let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

// SCWindow exposes: .windowID, .title, .owningApplication (.applicationName, .bundleIdentifier, .processID), .frame, .isOnScreen
let terminalWindows = content.windows.filter {
    ["Ghostty", "iTerm2", "Terminal", "Alacritty", "kitty", "WezTerm"].contains($0.owningApplication?.applicationName ?? "")
}

let browserWindows = content.windows.filter {
    ["Safari", "Google Chrome", "Arc", "Firefox"].contains($0.owningApplication?.applicationName ?? "")
    && ($0.title?.contains("localhost") ?? false)
}
```

**tmux limitation:** ScreenCaptureKit sees terminal *windows*, not individual tmux *panes*. For pane-level text capture, complement with `tmux capture-pane -t <target> -p`.

### Performance

- `SCScreenshotManager.captureImage()` is async, non-blocking, hardware-accelerated
- GPU memory-backed buffers reduce CPU involvement
- Single screenshot is sub-frame time on Apple Silicon
- Recording at 5-10 fps for code sessions has negligible resource impact
- HEVC hardware encoding on Apple Silicon has near-zero CPU overhead

### File Formats

| Format | Use For | Trade-off |
|--------|---------|-----------|
| PNG | Screenshots | Lossless (text readability), ~1-5 MB |
| JPEG (0.85) | Screenshots (storage-constrained) | ~200KB-1MB, slight artifacts on text |
| HEVC/.mov | Recordings | Hardware-encoded, ~50% smaller than H.264 |

**Recommendation:** PNG for screenshots (lossless matters for code), HEVC in .mov for recordings.

---

## 2. Permissions Model

### Screen Recording Permission (Required)

- ScreenCaptureKit requires **Screen Recording** permission in System Settings > Privacy & Security
- First call to `SCShareableContent.current` triggers the system permission dialog
- macOS 15 Sequoia re-prompts users **monthly** (down from weekly in earlier betas)
- Persistent Content Capture entitlement exists but requires Apple approval

### Required Changes

1. Add `NSScreenCaptureUsageDescription` to Info.plist
2. Check permission early: `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
3. No sandbox entitlement needed (app is not sandboxed)
4. Audio capture is bundled under the same permission (no separate dialog)

### Recommendation

Request permission at first launch or when user enables capture features. Show a clear explanation of what will be captured and why.

---

## 3. Architecture: IPC for Capture Triggering

### Recommended: Extend existing `hud-hook serve` HTTP endpoints

The critical constraint: **the Rust `hud-hook` server cannot call ScreenCaptureKit** — it requires an NSApplication run loop (GUI process). The architecture must be two-hop:

```
CLI Agent → POST /runtime/capture/request → Rust Runtime Service (stores pending request)
                                                    ↓
Swift App ← polls /runtime/snapshot ← detects pending capture
    ↓
Executes ScreenCaptureKit capture
    ↓
Saves artifacts to ~/.capacitor/runtime/captures/
    ↓
POST /runtime/capture/complete → Rust Runtime Service (clears pending, updates checkpoint)
```

### Why Not Alternatives

| Approach | Verdict |
|----------|---------|
| XPC Services | Overkill, adds deployment complexity |
| Unix domain sockets | Redundant (already have authenticated HTTP) |
| File-system signaling | Fragile, polling slower than HTTP |
| NSDistributedNotificationCenter | Can't carry payload, unreliable, code signing required on macOS 15+ |

### Integration Points

- `serve.rs:92-117` — add `POST /runtime/capture/request` and `POST /runtime/capture/complete` endpoints
- `run_types.rs` — extend `CheckpointPacket` or `ActiveCheckpoint` with capture metadata
- `RuntimeClient.swift` — Swift detects and acts on pending captures
- New `CaptureService.swift` — actor-based capture execution

---

## 4. What to Capture

### Priority Tiers

| Priority | Target | Discovery Method |
|----------|--------|-----------------|
| 1 (always) | Terminal window (agent's tmux session) | Match by app name + window title containing session name |
| 2 (if found) | Browser showing localhost | Match browser app + title containing "localhost:" |
| 3 (on-demand) | User-specified window | On-demand "Capture Now" button |

### Window Discovery

- **Terminal matching:** Use existing `RoutingTarget` session names from domain types
- **Browser URL detection:** Window title matching is simplest and works across browsers. AppleScript can query exact URLs for Chrome/Safari if needed
- **Never capture all visible windows** — privacy risk (email, messaging, passwords)

---

## 5. Recording Strategy

### Phase-Based Recording (Recommended)

- Start recording when an agent phase begins
- Stop recording at checkpoint
- Use `SCRecordingOutput` (macOS 15+) for minimal code
- Fall back to AVAssetWriter pattern for macOS 14

### Configuration

```swift
let config = SCStreamConfiguration()
config.minimumFrameInterval = CMTime(value: 1, timescale: 5) // 5 fps
config.width = 2560  // or match window dimensions
config.height = 1440
config.capturesAudio = false  // No value for headless CLI agents
config.showsCursor = true
```

### Ring Buffer (Future Enhancement)

If periodic/retroactive capture is needed later:
- Store compressed CMSampleBuffer frames in a circular buffer
- Use VideoToolbox hardware encoder to compress before buffering
- 30-second buffer at 1080p/60fps fits in memory on Apple Silicon
- Flush to AVAssetWriter when checkpoint triggers

---

## 6. Storage Model

### Layout

```
~/.capacitor/runtime/captures/
  {run_id}/{checkpoint_id}/
    terminal-001.png
    browser-001.png
    phase-recording.mov
    capture-manifest.json
```

### Capture Manifest

```json
{
  "captured_at": "2026-03-21T14:30:00Z",
  "run_id": "run-abc",
  "checkpoint_id": "ckpt-001",
  "captures": [
    {
      "type": "screenshot",
      "target": "terminal",
      "window_title": "capacitor - tmux:agent-1",
      "app": "Ghostty",
      "path": "terminal-001.png",
      "width": 2560,
      "height": 1440
    }
  ]
}
```

### Integration with Existing Manifests

Captures integrate into the existing `DelegationReviewManifest.artifacts` array — they appear automatically in the "ARTIFACTS" section of the review window. The `Artifact` struct already has `label` and `path` fields.

### Retention

Prune captures for completed/cancelled runs after 7 days. Treat as debugging aids, not permanent storage.

---

## 7. Mermaid Diagram Rendering

### Recommended: Live Rendering in Review Window

The coding agent produces Mermaid source text as a checkpoint artifact. Store the source as a text file. Render it live in the review window using one of:

| Approach | Pros | Cons |
|----------|------|------|
| **WKWebView + mermaid.js** | Full Mermaid support, interactive | Requires web view in view hierarchy |
| **BeautifulMermaid Swift package** | Native, fast, no JS deps | Only 5 diagram types (Flowchart, State, Sequence, Class, ER) |
| **`mmdc` CLI** | Complete support, batch export | Requires Node.js + Puppeteer (~200MB) |

**Recommendation:** Use WKWebView + mermaid.js for review window display. Consider BeautifulMermaid for quick native previews. Avoid mmdc for a desktop app (dependency weight).

For export as image artifacts, the WKWebView can `takeSnapshot()` to produce PNG/JPEG.

---

## 8. Security Considerations

1. **Targeted capture only** — never capture full screen. Use `SCContentFilter(.desktopIndependentWindow, window:)` for specific windows.
2. **Allow-list apps** — only capture from terminal emulators, browsers, and IDEs. Never capture messaging, email, or password managers.
3. **User transparency** — show what was captured in the review window. User can delete captures before approving.
4. **Permission explanation** — clear `NSScreenCaptureUsageDescription` explaining the feature.
5. **No audio** — headless CLI agents produce no meaningful audio.

---

## 9. Proposed Rust Domain Type Extensions

### CheckpointPacket Extension

```rust
pub struct CheckpointPacket {
    pub kind: CheckpointKind,
    pub title: String,
    pub summary: Option<String>,
    pub brief_path: Option<String>,
    pub manifest_path: Option<String>,
    // New fields:
    pub media_artifacts: Vec<MediaArtifact>,
    pub mermaid_sources: Vec<MermaidSource>,
    pub capture_requested: bool,
}

pub struct MediaArtifact {
    pub artifact_type: MediaArtifactType,
    pub path: String,
    pub label: String,
    pub metadata: Option<String>, // JSON string with width, height, duration, etc.
}

pub enum MediaArtifactType {
    Screenshot,
    Recording,
    Diagram,
}

pub struct MermaidSource {
    pub label: String,
    pub source: String,
    pub diagram_type: Option<String>, // flowchart, sequence, state, etc.
}
```

### ActiveCheckpoint Extension

```rust
pub struct ActiveCheckpoint {
    // ... existing fields ...
    pub media_artifacts: Vec<MediaArtifact>,
    pub capture_status: CaptureStatus,
}

pub enum CaptureStatus {
    NotRequested,
    Pending,
    InProgress,
    Completed,
    Failed { reason: String },
}
```

---

## 10. Proposed Swift CaptureService

```swift
import ScreenCaptureKit

actor CaptureService {
    enum CaptureTarget {
        case terminal(sessionName: String)
        case browser(urlPattern: String)
        case window(windowID: UInt32)
    }

    func captureWindow(_ window: SCWindow) async throws -> CGImage {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2  // Retina
        config.height = Int(window.frame.height) * 2
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )
    }

    func discoverTargets(for targets: [CaptureTarget]) async throws -> [SCWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        var matched: [SCWindow] = []
        for target in targets {
            switch target {
            case .terminal(let sessionName):
                let terminals = content.windows.filter { w in
                    let isTerminal = ["Ghostty", "iTerm2", "Terminal", "Alacritty", "kitty", "WezTerm"]
                        .contains(w.owningApplication?.applicationName ?? "")
                    return isTerminal && (w.title?.contains(sessionName) ?? false)
                }
                matched.append(contentsOf: terminals)
            case .browser(let urlPattern):
                let browsers = content.windows.filter { w in
                    let isBrowser = ["Safari", "Google Chrome", "Arc", "Firefox"]
                        .contains(w.owningApplication?.applicationName ?? "")
                    return isBrowser && (w.title?.contains(urlPattern) ?? false)
                }
                matched.append(contentsOf: browsers)
            case .window(let windowID):
                if let window = content.windows.first(where: { $0.windowID == windowID }) {
                    matched.append(window)
                }
            }
        }
        return matched
    }
}
```

---

## Sources

- [ScreenCaptureKit Documentation](https://developer.apple.com/documentation/screencapturekit/)
- [SCScreenshotManager Documentation](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [SCRecordingOutput Documentation](https://developer.apple.com/documentation/screencapturekit/screcordingoutput)
- [WWDC22: Meet ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2022/10156/)
- [WWDC23: What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)
- [WWDC24: Capture HDR content](https://developer.apple.com/videos/play/wwdc2024/10088/)
- [Nonstrict: Recording to disk with ScreenCaptureKit](https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/)
- [ScreenCaptureKit-Recording-example (GitHub)](https://github.com/nonstrict-hq/ScreenCaptureKit-Recording-example)
- [screencapturekit-rs (Rust crate)](https://crates.io/crates/screencapturekit)
- [BeautifulMermaid Swift package](https://github.com/lukilabs/beautiful-mermaid-swift)
- [mermaid-cli](https://github.com/mermaid-js/mermaid-cli)
- [macOS Sequoia monthly permission prompts](https://mjtsai.com/blog/2024/08/08/sequoia-screen-recording-prompts-and-the-persistent-content-capture-entitlement/)
- [GIPHY ring buffer implementation](https://engineering.giphy.com/doing-it-live-at-giphy-with-avfoundation/)
- [AVAssetWriter Documentation](https://developer.apple.com/documentation/avfoundation/avassetwriter)

# Adversarial Review: Screen Capture & Recording Research

> Date: 2026-03-21
> Status: Review complete
> Reviewer: Adversarial review agent

---

## Verdict Summary

The research is directionally correct on the primary recommendation (ScreenCaptureKit), but contains several significant gaps, one factually misleading claim, and misses a compelling alternative architecture that avoids ScreenCaptureKit entirely for the highest-priority capture target (terminal content). Below is the section-by-section analysis.

---

## 1. ScreenCaptureKit API Validation

### Correct claims

- `CGWindowListCreateImage` is deprecated (macOS 14) and obsoleted (macOS 15). ScreenCaptureKit is the only supported path forward. This is confirmed across Apple documentation and third-party migration reports (FreeRDP, KeePassXC, OBS).
- `SCScreenshotManager` is the correct replacement for single-frame captures. The API surface (`captureImage`, `captureSampleBuffer`) is accurately described.
- The OBS benchmark claim (50% less CPU, 15% less RAM) originates from Apple's WWDC22 "Take ScreenCaptureKit to the next level" session. However, this benchmark was for **60fps continuous streaming in a gaming workload**, not for screenshot capture. The research cites it correctly but the comparison context is misleading when applied to Capacitor's use case.

### Gotchas the research missed

**1. Image sizing is NOT automatic.** Unlike `CGWindowListCreateImage`, which auto-sized output to the captured window, `SCScreenshotManager.captureImage()` always produces images at the exact `width`/`height` specified in `SCStreamConfiguration`. If you set dimensions that don't match the window's aspect ratio, you get stretched or letterboxed output. The proposed `CaptureService.swift` code correctly scales by 2x for Retina, but does not handle non-Retina displays or mixed-DPI setups (e.g., external monitors at 1x alongside a Retina laptop display). This is a real gotcha on developer workstations with heterogeneous displays.

**2. `CGDisplayStream` is not a viable alternative.** The research rightly chose SCK over `CGDisplayStream`, but never explicitly mentions that `CGDisplayStream` is also obsoleted in macOS 15 alongside `CGWindowListCreateImage`. Anyone evaluating alternatives should know this is a dead end.

**3. `AVCaptureScreenInput` is also deprecated.** This was the AVFoundation-based screen capture input, deprecated in macOS 12.3 in favor of ScreenCaptureKit. The research does not mention it at all. For completeness, this should be documented as a non-option.

**4. Minimized/occluded window behavior.** The research does not address what happens when the target terminal window is minimized, behind other windows, or on another Space. ScreenCaptureKit with `desktopIndependentWindow` filter CAN capture minimized windows, but the behavior is not guaranteed to produce current content for windows that have been minimized for extended periods (the WindowServer may stop compositing them). This is particularly relevant for Capacitor: coding agents run in tmux, and users may not have the terminal window visible or foregrounded.

### Assessment: MOSTLY VALID, with gaps on edge cases

---

## 2. IPC Architecture Challenge

### The two-hop pattern is overcomplicated for the primary use case

The proposed architecture is:
```
CLI Agent -> POST /runtime/capture/request -> Rust -> Swift polls -> executes SCK -> saves file -> POST /runtime/capture/complete -> Rust
```

This introduces latency, complexity, and failure modes. Let me challenge it from multiple angles.

**Challenge 1: Darwin notifications for instant wake-up.**
The research dismisses `NSDistributedNotificationCenter` but does not consider Darwin notifications (`notify_post`/`notify_register_dispatch`). These are lightweight, kernel-mediated, process-to-process signals that:
- Work without code signing requirements (unlike `NSDistributedNotificationCenter` on Sequoia)
- Have microsecond delivery latency
- Can be posted from the Rust process using libc FFI (`notify_post` is a C function)
- Can be received in Swift via `notify_register_dispatch`

The pattern would be: Rust receives capture request via HTTP, stores it, posts a Darwin notification. Swift receives it instantly (no polling delay), executes SCK, saves result, notifies Rust via HTTP POST. This eliminates the polling latency, which at a typical 1-2 second poll interval adds significant delay.

**Challenge 2: Why not call SCK from Rust via the UniFFI bridge?**
The research states "the Rust `hud-hook` server cannot call ScreenCaptureKit -- it requires an NSApplication run loop." This deserves scrutiny:

- `SCScreenshotManager.captureImage()` is an async function that does NOT strictly require an NSApplication run loop. It requires a connection to the WindowServer, which requires a GUI session (login session). The Rust `hud-hook` process runs as a daemon-like HTTP server -- it likely does NOT have a WindowServer connection.
- However, the `screencapturekit-rs` crate (v1.5.0) exposes `SCScreenshotManager` from Rust and works in processes that have a WindowServer connection. The question is whether `hud-hook` could be modified to establish one.
- The more practical path: since UniFFI already bridges Rust and Swift, the Swift app could expose a capture function that the Rust side calls through the bridge. But this inverts the current call direction (Rust currently exposes functions TO Swift, not the reverse).

**Verdict on the architecture:** The two-hop HTTP pattern is reasonable given the existing architecture, but it should use Darwin notifications for the wake-up signal rather than relying on polling. The polling approach adds 0.5-2 seconds of latency per capture request for no good reason.

**Challenge 3: Simpler alternative -- just do it all in Swift.**
Since the Swift app already polls `/runtime/snapshot` and detects checkpoint state changes, the simplest architecture might be: when the Swift app sees a new checkpoint in the snapshot, it autonomously captures the terminal window. No new HTTP endpoints needed. No IPC for capture triggering at all. The Rust side just needs a field in the checkpoint data indicating whether media capture is desired, which the proposed `capture_requested: bool` already provides.

### Assessment: VALID ARCHITECTURE, but overengineered. Darwin notifications + autonomous Swift-side triggering would be simpler.

---

## 3. Storage Model: Image Format Challenge

### PNG is the correct default for screenshots of code

The research recommends PNG, and this is correct. Here is the evidence:

- **WebP lossless is NOT better for text.** A detailed benchmark by Ctrl.blog and Siipola found that for text-heavy images and screenshots, PNG's DEFLATE compression actually outperforms WebP lossless. PNG was 3.06x smaller than WebP for text-based images in one benchmark. WebP lossless is 26% smaller than PNG on average for *photographic content*, but this advantage reverses for screenshots with large flat-color regions and sharp text edges.

- **HEIC/HEIF lossless exists but has trade-offs.** HEIC supports lossless mode, and Apple is moving toward HEIC as the default screenshot format (macOS Tahoe 26 defaults to HEIC for HDR screenshots). However: lossless HEIC files are not meaningfully smaller than PNG for screenshot content, the encoding is more CPU-intensive, and tooling compatibility is worse (not all image viewers/editors handle HEIC well). For a debugging artifact with 7-day retention, universal compatibility matters.

- **JPEG XL lossless is genuinely 20-30% smaller than PNG** for screenshots, with better compression of flat regions. It's technically superior. However: Apple does not ship native JPEG XL support in macOS (no ImageIO codec), Safari dropped JPEG XL support, and adding a dependency for a marginal size improvement on 7-day-retention debugging artifacts is not worth it.

### One valid alternative: consider HEIC for recordings

The research already recommends HEVC for recordings, which is correct. HEVC in .mov with hardware encoding is the right call for Apple Silicon.

### Missed consideration: image dimensions and file size

The research lists "~1-5 MB" for PNG screenshots. For a 2560x1440 Retina capture of a terminal (which would actually be 5120x2880 pixels at 2x), a PNG could easily be 5-15 MB depending on content complexity. The research should quantify expected file sizes at actual capture dimensions and discuss whether downscaling (e.g., capturing at 1x instead of 2x Retina) is acceptable for debugging artifacts.

### Assessment: PNG IS CORRECT. The format recommendation stands.

---

## 4. Mermaid Rendering: WKWebView Challenge

### WKWebView offscreen rendering is unreliable -- this is a real risk

The research recommends "WKWebView + mermaid.js" for live rendering in the review window. This has a well-documented failure mode:

**WKWebView does not reliably render content when offscreen or not in the view hierarchy.** Apple Developer Forums threads from 2017 through 2024 consistently report that:
- `takeSnapshot()` on an offscreen WKWebView produces blank/white images
- WKWebView throttles or stops rendering entirely when not visible
- The rendering process is out-of-process (WebContent process), so visibility detection is done by the system, not your code
- Workarounds (adding to window hierarchy at zero size, delayed snapshots) are fragile

For the review window use case, this is less of a problem because the WKWebView would be *visible* when the user is looking at it. But if you ever need to pre-render or export diagrams to PNG/SVG in the background, `takeSnapshot()` will be unreliable.

### Better recommendation: store Mermaid source, render on demand

The research actually suggests this as an option ("store the source as a text file"). This is the correct approach:

1. **Store Mermaid source text** as a checkpoint artifact (tiny, lossless, diffable)
2. **Render live in the review window** using WKWebView + mermaid.js only when the user opens it (the view is visible, so rendering works)
3. **Never pre-render to image** -- it adds complexity and the offscreen WKWebView issues make it fragile
4. If you eventually need static export, use the visible WKWebView's `takeSnapshot()` while it's on screen, triggered by a user action

### Alternative: BeautifulMermaid is too limited

The research correctly identifies that BeautifulMermaid only supports 5 diagram types. Coding agents frequently produce Gantt charts, pie charts, mindmaps, and other types that would silently fail. This is a non-starter as a primary renderer.

### Alternative: SVG rendering via Core Graphics

The research does not discuss this option. Mermaid.js can output SVG. If you capture the SVG string from the JS runtime, you could render it natively via `NSImage(data:)` or Core Graphics. This would work offscreen. However, it requires running mermaid.js at least once (in a WKWebView or JavaScriptCore) to produce the SVG, so it doesn't fully eliminate the WKWebView dependency -- it just decouples rendering from display.

### Assessment: RECOMMENDATION IS MOSTLY SOUND, but should explicitly warn against offscreen/background rendering and commit to render-on-demand only.

---

## 5. Missing Alternatives

### 5A. `tmux capture-pane` + Freeze: THE STRONGEST MISSED ALTERNATIVE

This is the most significant gap in the research. For Capacitor's **Priority 1 target** (terminal window showing the agent's tmux session), ScreenCaptureKit is overkill. The agents run as headless `claude -p` processes in tmux. The app already knows the tmux session names. Therefore:

```bash
tmux capture-pane -t <target> -p -e  # Capture pane content with ANSI escape codes
```

Combined with [Charmbracelet Freeze](https://github.com/charmbracelet/freeze) (a Go binary, ~10MB, no runtime deps):

```bash
tmux capture-pane -t <target> -p -e | freeze --output screenshot.png
```

This approach:
- **Requires NO screen recording permission** -- it reads from tmux's internal buffer, not the screen
- **Works when the terminal is minimized, occluded, or on another Space**
- **Works when the terminal is not even running** (tmux sessions persist independently)
- **Captures the exact text content** the agent sees, not a pixel-level screenshot of whatever the terminal happens to be rendering
- **Is deterministic** -- same pane content always produces the same image
- **Has zero privacy concerns** -- only captures the specific tmux pane, never other windows

The downside: it captures text, not pixels. You won't see custom terminal themes, ligatures, or graphical terminal features. For debugging coding agent sessions, text fidelity matters far more than visual fidelity.

**Recommendation: Use `tmux capture-pane` + Freeze for Priority 1 (terminal captures). Reserve ScreenCaptureKit for Priority 2 (browser) and Priority 3 (arbitrary windows). This dramatically reduces the permission burden.**

### 5B. `screencapture` CLI tool

The built-in macOS `screencapture` command supports window-level capture:
```bash
screencapture -l <windowID> output.png
```

This still requires Screen Recording permission and uses the deprecated `CGWindowListCreateImage` under the hood. It's simpler to invoke but:
- Deprecated API path (will break eventually)
- Still requires the same permission as ScreenCaptureKit
- Less control over output format and configuration
- Cannot capture specific displays or application filters

**Verdict: Not recommended. Same permission cost, worse API.**

### 5C. Accessibility APIs (AXUIElement)

AXUIElement can read UI element hierarchies, labels, and states, but it **cannot capture pixel content** of windows. The Accessibility permission is separate from Screen Recording, but it only gives you the accessibility tree (text labels, button states, hierarchy), not a visual screenshot.

Some projects (like macapptree) combine AX tree extraction with window-level screenshots, but the screenshot part still requires Screen Recording permission.

**Verdict: Not useful for visual capture. However, AX APIs could complement `tmux capture-pane` by providing metadata about which windows are present without needing Screen Recording permission.**

### 5D. Rust-native screen capture crates

Two viable options exist:

1. **`screencapturekit` (v1.5.0)** -- Rust bindings for Apple's ScreenCaptureKit. Supports `SCScreenshotManager` (macOS 14+), `SCRecordingOutput` (macOS 15+). Actively maintained. This could theoretically allow the Rust process to do captures directly, BUT it still requires a WindowServer connection that `hud-hook` likely lacks.

2. **`xcap` (v0.8.2)** -- Cross-platform screen capture in Rust. Supports macOS window and display capture. Uses `CGWindowListCreateImage` on macOS, which is deprecated/obsoleted. Not a viable long-term option.

**Verdict: `screencapturekit-rs` is interesting for future exploration but does not solve the WindowServer connection problem for the `hud-hook` daemon. The Swift app is still the right place to call SCK.**

---

## 6. Performance Reality Check

### The "negligible resource impact" claim is misleading

The research states: "Recording at 5-10 fps for code sessions has negligible resource impact." This is not substantiated and is likely wrong for continuous recording. Here's why:

**Memory pressure:**
- Each captured frame at 2560x1440 (pre-Retina) is ~14.7 MB uncompressed (BGRA). At 2x Retina (5120x2880), it's ~59 MB per frame.
- At 5 fps, that's 73.5 - 295 MB/sec of raw pixel data flowing through the system.
- ScreenCaptureKit uses GPU-backed `IOSurface` buffers, so this doesn't land in app heap memory. But it does consume GPU memory and generates memory bus traffic.
- The `SCStreamConfiguration.queueDepth` controls how many frames are buffered. Default is 3, max recommended is 8. At Retina resolution, 8 frames = ~472 MB of GPU memory reserved for capture buffers alone.

**Disk I/O:**
- HEVC hardware encoding at 5 fps on Apple Silicon is indeed very efficient (~0.5-2% CPU).
- But the encoded output still needs to be written to disk. At 5 fps for code content (low motion, high detail), expect ~200-500 KB/sec for HEVC. Over a 30-minute agent phase, that's 360 MB - 900 MB per recording.
- With multiple concurrent agent sessions (Capacitor's core use case), multiply accordingly.

**Energy impact:**
- The hardware video encoder (Apple's Media Engine) is power-efficient, but it's not free. Activity Monitor's "Energy Impact" metric would show a measurable increase.
- More importantly: maintaining an active `SCStream` prevents the display from entering low-power idle states. This has a noticeable impact on laptop battery life even if the per-frame encoding cost is low.
- Apple's own documentation recommends stopping capture when not actively needed to reduce energy consumption.

**Realistic recommendation:**
- **Single screenshots at checkpoints**: truly negligible impact. Sub-millisecond capture, one-time PNG encode. This is fine.
- **Continuous 5fps recording during agent phases**: measurable but likely acceptable on desktop Macs. Problematic on laptops on battery. Should be opt-in, not default. Should auto-pause when on battery power.
- The research's ring buffer idea (30 seconds at 1080p/60fps) is wildly expensive for this use case. At 60fps Retina, you're looking at 3.5 GB/sec of raw data and significant GPU memory. This should be flagged as "nice to have, not recommended."

### Assessment: CLAIM IS MISLEADING. Screenshots are negligible; continuous recording is measurably impactful and should be opt-in.

---

## 7. Permission UX Reality

### The monthly re-prompt situation is worse than described

The research states "macOS 15 Sequoia re-prompts users monthly." The actual situation as of macOS 15.2+:

1. **macOS 15.0**: Weekly re-prompts (beta), changed to monthly before release
2. **macOS 15.1**: Apple reduced frequency for "regularly used apps" -- but never specified the exact cadence. Apps you use daily may see fewer prompts; apps you use occasionally still get monthly prompts.
3. **macOS Tahoe (26)**: No public information on whether the re-prompt cadence changed further.

### Can you avoid re-prompts for a non-App Store app?

**Option 1: Persistent Content Capture entitlement.**
This is a restricted entitlement (`com.apple.developer.persistent-content-capture`) that suppresses re-prompts entirely. However:
- Apple provides no public documentation on how to request it
- Developers report waiting months with no response
- It appears to be granted only to enterprise remote-desktop apps (AnyDesk, Jump Desktop)
- A non-App-Store developer tool is unlikely to be approved

**Option 2: Amnesia app.**
Amnesia (by Jordi Bruin) modifies the TCC database to set the permission expiry date to the far future. It works, but:
- Relies on being able to write to the TCC database, which Apple may lock down further
- Requires the user to install a separate app
- Not a solution you can ship as part of Capacitor

**Option 3: Design around it.**
The best approach for Capacitor: **use `tmux capture-pane` for terminal captures (no permission needed), and only use ScreenCaptureKit for browser/arbitrary window captures (opt-in).** This way, the core screenshot functionality works without any Screen Recording permission. Users who want browser captures opt in and accept the permission UX.

### Assessment: THE RESEARCH UNDERSTATES THE UX FRICTION. Permission re-prompts are a significant adoption barrier that the architecture should be designed to minimize.

---

## 8. Top 3 Risks

### Risk 1: Permission fatigue kills adoption (HIGH)

Screen Recording permission is the single most intrusive macOS permission. Users get a system dialog, monthly re-prompts, and a persistent menu bar indicator (recording dot) while capture is active. For a developer tool that's supposed to reduce friction, adding Screen Recording permission is a significant UX tax.

**Mitigation:** Use `tmux capture-pane` for terminal captures. Only request Screen Recording permission when the user explicitly enables browser/window capture features.

### Risk 2: Continuous recording storage explosion (MEDIUM)

Multiple concurrent agent sessions, each recording at 5fps, can generate gigabytes of video data per day. The 7-day retention policy means up to ~50 GB of capture data for heavy users. The research proposes storing in `~/.capacitor/runtime/captures/` but does not discuss:
- Disk space monitoring or warnings
- Maximum storage budget with automatic pruning
- What happens when the disk is full
- APFS cloning/deduplication (captures of idle terminals are mostly duplicate frames)

**Mitigation:** Implement a storage budget (e.g., 5 GB default cap), prune oldest captures first, and default to screenshots-at-checkpoints rather than continuous recording.

### Risk 3: Minimized/offscreen window capture produces stale or blank content (MEDIUM)

Developers frequently minimize or hide terminal windows while agents work. ScreenCaptureKit with `desktopIndependentWindow` filter can capture minimized windows, but:
- WindowServer may not composite minimized windows at full fidelity
- Windows on other Spaces may produce stale framebuffer content
- The captured content may not reflect what the agent is actually doing (the terminal emulator may have buffered but not rendered recent output)

This silently degrades the value of captures without any error signal.

**Mitigation:** Prefer `tmux capture-pane` for terminal content (always current, regardless of window state). For visual captures, detect window visibility and warn when capturing potentially stale content.

---

## Summary of Actionable Recommendations

| # | Recommendation | Priority |
|---|----------------|----------|
| 1 | Add `tmux capture-pane` + Freeze as the PRIMARY terminal capture method (no Screen Recording permission needed) | High |
| 2 | Demote ScreenCaptureKit to opt-in for browser/arbitrary window captures only | High |
| 3 | Replace polling-based capture triggering with Darwin notifications (`notify_post`/`notify_register_dispatch`) | Medium |
| 4 | Consider autonomous Swift-side capture triggering (on checkpoint detection) instead of new HTTP endpoints | Medium |
| 5 | Make continuous recording opt-in with battery-awareness; default to screenshots-at-checkpoints | Medium |
| 6 | Add storage budget and automatic pruning for captures | Medium |
| 7 | Commit to render-on-demand for Mermaid (store source, render only in visible WKWebView) | Low |
| 8 | Document the Retina/multi-DPI gotcha for `SCStreamConfiguration` dimensions | Low |
| 9 | Quantify actual file sizes at expected capture dimensions | Low |

---

## Sources

- [Nonstrict: A look at ScreenCaptureKit on macOS Sonoma](https://nonstrict.eu/blog/2023/a-look-at-screencapturekit-on-macos-sonoma/)
- [Apple: SCScreenshotManager Documentation](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
- [Apple: WWDC22 Take ScreenCaptureKit to the next level](https://developer.apple.com/videos/play/wwdc2022/10155/)
- [Apple: WWDC23 What's new in ScreenCaptureKit](https://developer.apple.com/videos/play/wwdc2023/10136/)
- [MacRumors: macOS Sequoia Screen Recording Permissions Monthly](https://www.macrumors.com/2024/08/15/macos-sequoia-screen-recording-app-permissions/)
- [Daring Fireball: Monthly Screen Recording Prompts](https://daringfireball.net/linked/2024/08/17/macos-15-beta-6-monthly-screen-recording-prompts)
- [TidBITS: How to Avoid Sequoia's Repetitive Screen Recording Permissions Prompts](https://tidbits.com/2024/09/23/how-to-avoid-sequoias-repetitive-screen-recording-permissions-prompts/)
- [iDownloadBlog: macOS Sequoia 15.1 reduces screen recording prompts](https://www.idownloadblog.com/2024/10/09/macos-sequoia-15-1-macos-screen-recording-prompts-frequency-reduced/)
- [9to5Mac: Amnesia app fixes Sequoia permission nags](https://9to5mac.com/2024/09/24/macos-sequoia-screen-recording-permission-nags-can-now-be-permanently-vanquished/)
- [OBS ScreenCaptureKit PR](https://github.com/obsproject/obs-studio/pull/5875)
- [screencapturekit-rs on crates.io](https://crates.io/crates/screencapturekit)
- [xcap Rust crate](https://github.com/nashaofu/xcap)
- [Charmbracelet Freeze](https://github.com/charmbracelet/freeze)
- [Nonstrict: Recording to disk with ScreenCaptureKit](https://nonstrict.eu/blog/2023/recording-to-disk-with-screencapturekit/)
- [Nonstrict: Darwin Notifications for app extensions](https://nonstrict.eu/blog/2023/darwin-notifications-app-extensions/)
- [Apple: Darwin Notification API](https://developer.apple.com/documentation/darwinnotify)
- [Apple Developer Forums: WKWebView offscreen rendering](https://developer.apple.com/forums/thread/90732)
- [Apple Developer Forums: WKWebView takeSnapshot blank](https://developer.apple.com/forums/thread/727992)
- [Siipola: Best lossless image format comparison](https://siipo.la/blog/whats-the-best-lossless-image-format-comparing-png-webp-avif-and-jpeg-xl)
- [Ctrl.blog: WebP FLIF PNG comparison](https://www.ctrl.blog/entry/webp-flif-comparison.html)
- [DPReview: macOS Tahoe screenshots in HEIC](https://www.dpreview.com/forums/threads/macos-26-tahoe-screenshots-in-heic.4817577/)
- [FreeRDP: CGDisplayStream obsoleted in macOS 15](https://github.com/FreeRDP/FreeRDP/issues/10558)
- [KeePassXC: CGDisplayStream deprecation discussion](https://github.com/keepassxreboot/keepassxc/discussions/10308)

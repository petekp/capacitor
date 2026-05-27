# Preview Work Strategy

Status: strategy recommendation
Date: 2026-05-27
Scope: Capacitor Work Batches, batch worktrees, visual/native/web verification, and operator-facing review

## Thesis

Capacitor needs a first-class **Preview Work** capability.

The product problem is not "how does the user find the right worktree?" The
product problem is "how does the user inspect the work the agent claims is
done without learning the platform plumbing?"

For web projects, the answer is often a local dev server plus browser
automation. For native macOS/iOS projects, the answer is a build product, app
identity, simulator/device target, and a launch proof. For desktop wrappers,
the answer may be a dev process or packaged app. For command-line changes, the
"preview" is command output, logs, fixtures, or generated artifacts. Capacitor
should hide those differences behind one Work Batch action:

```text
Open Preview
```

The Work Batch should still use the same trust spine we already have: Task
claim, Checkpoint, Done report, internal evidence, and Unresolve. Preview Work
should extend that spine; it should not become a separate runner, flow engine,
or approval platform.

## Evidence Is Internal

Evidence is not the user experience.

Evidence is the internal substrate Capacitor and the worker use to preserve
context, recover from confusion, audit what happened, and decide whether a Done
claim is credible enough to present. The operator-facing layer should be much
simpler:

```text
Status
Result
Preview
Risk
Action
```

That means the user should usually see:

```text
Done
Ready to inspect
Preview failed
Needs your input
Still running
```

Raw logs, screenshots, commands, diffs, claim files, Done reports, and preview
artifacts should still exist, but they belong behind disclosure or in a debug
path. The default surface should answer: what happened, can I inspect it, is
anything risky, and what can I do next?

## Current Capacitor Ground Truth

Confirmed from the repo:

- Capacitor's product language says Tasks should move toward execution as soon
  as captured, while checkpoints are the safeguard when continuing would be
  risky or ambiguous (`CONTEXT.md:7`, `CONTEXT.md:15`).
- A Work Batch is the visible unit of related Tasks, and a Batch Worktree is the
  isolated checkout for that batch (`CONTEXT.md:71`, `CONTEXT.md:123`).
- The Work Batch Context Mirror is agent-readable but not canonical state
  (`CONTEXT.md:59`, `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:142`).
- The mirror already instructs Claude Code to write a Task claim before work,
  a Done report before saying done, and a Checkpoint request when input is
  needed (`apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:146`).
- Claim artifacts live under `.capacitor/work-batch-claims`; projection accepts
  decoded claims only when their status is `working`
  (`apps/swift/Sources/Capacitor/Models/WorkBatchTaskClaim.swift:30`,
  `apps/swift/Sources/Capacitor/Models/WorkBatchTaskClaim.swift:48`).
- Done reports currently carry only `task_id`, `status`, `summary`,
  `evidence`, and `completed_at` (`apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:93`).
- Work Batch state has queued, working, needs-you, and done Task states, plus
  Ready, Working, Waiting, Compacting, and Idle batch statuses
  (`apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:3`,
  `apps/swift/Sources/Capacitor/Models/WorkBatchState.swift:41`).
- Managed worktrees are created under `.capacitor/worktrees/<name>` using
  `git worktree add` (`apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift:151`).
- Swift owns presentation, orchestration, terminal side effects, and macOS
  activation, while Rust owns runtime semantics, identity, ingest, reducer
  state, and persistence (`docs/ARCHITECTURE.md:18`).
- Existing app manual testing already needs a wrong-build guard because macOS
  can make it hard to know which app binary the user is seeing (`AGENTS.md:62`).

Implication: Preview Work should be a **Work Batch result and launch layer**
backed by internal evidence. It should not replace the batch session, and it
should not ask the user to manually rebuild from the batch worktree.

Confidence split:

- Confirmed: Capacitor already has Work Batch identity, Batch Worktrees,
  claim/checkpoint/done artifacts, and a clear Swift/Rust boundary.
- Confirmed: the current Done report does not have a structured preview field.
- Inferred: preview should attach to Done and internal evidence because that is
  the existing trust spine and avoids introducing a separate approval system.
- Inferred: preview sessions should be Work Batch-scoped because a Project may
  have multiple concurrent batch worktrees.
- Unresolved: the exact storage owner for preview sessions should be decided
  when implementation starts. Swift should own build/launch side effects; Rust
  may own persisted preview session records if they become part of canonical
  runtime state.

## Platform Capability Map

| Platform | Natural preview | What Capacitor can automate | Hard constraints | Good first UX |
|---|---|---|---|---|
| Web app | Dev server or production-style local server in the batch worktree | Choose/run script, allocate port, open browser, capture screenshots, run Playwright/Cypress when available | Ports, env vars, DB/services, auth, migrations, HMR state, false green if wrong checkout/server is open | `Open Preview` opens the exact local URL and keeps proof internal |
| Static site/docs | Build output or static server | Run build, serve output, open browser/file, capture screenshots or link checks | Build time, asset paths, base URLs, stale generated output | `Open Preview` opens built artifact with build log |
| Native macOS app | Built `.app` from the batch worktree | Build, locate bundle, launch exact path, record bundle id/path/pid, capture screenshot | Bundle ID collisions, Launch Services ambiguity, signing, permissions, DerivedData, stale app processes, runtime state collisions | `Open Preview Build` launches a clearly labeled batch preview app |
| iOS app | Simulator/device build | Build for simulator/device, boot target, install, launch, capture screenshot/logs | Signing, simulator availability, device trust, bundle ID collisions, provisioning, build time | `Open in Simulator` with target and build proof |
| Android app | Emulator/device build | Build/install/launch APK, collect logs/screenshots | SDK availability, emulator state, signing, app id collisions, slow first build | `Open in Emulator` with build/install proof |
| Electron | Dev Electron process or packaged app | Run `electron-forge start`/project script, or package and launch app | App identity, child dev server, code signing for packaged app, stale app windows | `Open Desktop Preview` with dev/package mode label |
| Tauri | `tauri dev` process or bundled app | Run `tauri dev`, or build and launch bundle | Rust build time, frontend dev server, app identifier, physical device host rules | `Open Desktop Preview` with active process/build artifact |
| CLI/backend/library | Command output, tests, generated fixture, API response | Run declared verification command, collect stdout/stderr/artifacts | No visual surface; proof depends on command quality and test data | `View Result` rather than `Open Preview` |
| Design/artifact-only | Image, video, doc, fixture, rendered HTML/PDF | Display artifact, compare before/after, collect comments | No live app; artifact may not prove integration | `Review Artifact` in a preview rail |

## Source-Backed Platform Notes

### Web

Modern web tooling already exposes predictable preview hooks:

- Next.js has `dev`, `build`, and `start` commands; `next dev` supports port
  and hostname flags, and `next start` expects a prior build.
  Source: Next.js CLI docs, https://nextjs.org/docs/15/pages/api-reference/cli/next.
- Vite exposes `--host`, `--port`, `--open`, and `--strictPort` options for
  dev/preview commands.
  Source: Vite CLI docs, https://v5.vite.dev/guide/cli.
- Playwright can capture screenshots and compare visual snapshots.
  Sources: https://playwright.dev/docs/next/screenshots and
  https://playwright.dev/docs/next/test-snapshots.

Tradeoff: web is the easiest first platform because Capacitor can prove the
preview URL, port, process cwd, screenshot, and command output. The hard part is
not opening a browser; it is proving the open browser is backed by the batch
worktree and not by a stale dev server from the root checkout.

### Native macOS

Native macOS preview is harder because the user sees an app binary, not a URL.

Apple's command-line tooling supports building/querying/testing Xcode projects
from the command line through `xcodebuild`.
Source: Apple TN2339, https://developer.apple.com/library/archive/technotes/tn2339/_index.html.

macOS app identity matters. `CFBundleIdentifier` uniquely identifies a bundle,
and the system uses it for preferences, Launch Services, and other lookups.
Source: Apple Info.plist key reference,
https://developer-mdn.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html.

Tradeoff: a native preview that uses the same bundle identifier and display name
as the normal app is unreliable. It can foreground the wrong build, share user
defaults, collide with Launch Services, and reproduce the "wrong Capacitor
build" problem. A durable Capacitor preview needs explicit build identity:

- preview app display name
- preview bundle id or launch-by-path proof
- app path
- pid
- source worktree path
- git head
- build command
- build timestamp

For Capacitor itself, this likely means a dedicated `Capacitor Preview` build
mode rather than reusing `Capacitor Debug` for every batch preview.

### iOS and Mobile

iOS/mobile preview requires a target. A build alone is not a preview unless it
is installed and launched somewhere the user can inspect.

Apple's `xcodebuild` destination model supports simulator/device identifiers
for tests and builds. Source: Apple TN2339, same as above.

Expo illustrates the mobile tradeoff clearly: `expo start` can open on
simulators/devices, ports and URL modes matter, and simulator builds can be
produced without immediately launching a specific device. Source:
https://docs.expo.dev/more/expo-cli/.

Tradeoff: mobile preview should start with simulator support, not physical
devices. Device preview involves signing, trust, network reachability, and user
hardware state. Capacitor can still model it later as a target choice:

```text
Open Preview -> iPhone 16 Simulator
```

but it should not make device selection part of ordinary task capture.

Android has the same basic shape: build, install, launch, and observe. The
official Android command-line docs describe Gradle-wrapper builds, debug APKs,
and installing via Gradle install tasks or `adb`; emulator docs describe
starting named virtual devices and installing apps through `adb`. Sources:
https://developer.android.com/tools/building/building-cmdline and
https://developer.android.com/studio/run/emulator-commandline.

Tradeoff: Android should follow the same staged policy as iOS: emulator first,
physical devices later. Physical device preview adds USB debugging, trust,
driver, signing, and hardware-state dependencies that should not be part of the
first ordinary `Open Preview` path.

### Electron and Tauri

Desktop web-wrapper apps sit between web and native preview.

Electron's own docs point users toward packaging/rebranding for distribution
and recommend Electron Forge for packaging. Electron Forge exposes start,
package, make, and publish commands. Sources:
https://www.electronjs.org/docs/latest/tutorial/application-distribution/ and
https://www.electronforge.io/cli.

Tauri's docs describe `tauri dev` for desktop development, mobile dev commands,
frontend dev server handoff, and release builds. Sources:
https://v2.tauri.app/develop/ and https://v2.tauri.app/reference/cli/.

Tradeoff: these platforms often need two things at once: a frontend server and a
native shell process. Capacitor should not pretend this is just a web URL. The
preview adapter must record the supervising command, any child dev server URL,
and the launched app process.

### CLI, Backend, Library, and Artifact Work

Some work has no live visual surface. For those tasks, "preview" should become
result review:

- command output
- test result
- generated file
- API response
- before/after fixture
- rendered markdown/HTML/PDF
- screenshot or video artifact supplied by the agent

Tradeoff: forcing every task through a visual preview would make Capacitor
clunky. The unified feature should have multiple preview kinds, with visual
preview as one kind. The user-facing brief should summarize the result; the raw
proof remains internal unless the user opens details.

## Unified Product Feature: Preview Work

Preview Work is a Work Batch feature with five operator-facing states:

```text
Preview unavailable
Preview not needed
Preview building
Ready to inspect
Preview failed
```

The user-facing command should stay simple:

```text
Open Preview
```

When no live surface exists, the command becomes:

```text
View Result
```

The user should never need to choose "Next dev vs Vite vs Xcode vs simctl vs
Electron Forge." Capacitor should infer or store that choice.

## Proposed Model

### 1. Preview Capability

A project can expose one or more preview capabilities:

```json
{
  "id": "macos-debug-preview",
  "kind": "native_macos_app",
  "label": "macOS Preview",
  "worktree_policy": "batch",
  "build": {
    "command": "./scripts/dev/build-preview-app.sh",
    "expected_artifact": "apps/swift/CapacitorPreview.app"
  },
  "launch": {
    "mode": "app_path",
    "capture_pid": true
  },
  "evidence": {
    "screenshots": "optional",
    "logs": "required",
    "build_result": "required"
  }
}
```

This can start as inferred metadata, but inference should be advisory. Capacitor
should prefer an explicit preview capability once one exists because preview is
where a wrong guess becomes visible user pain. Good discovery inputs:

- `package.json` scripts
- `vite.config.*`, `next.config.*`
- `*.xcodeproj`, `Package.swift`
- `src-tauri/tauri.conf.json`
- Electron Forge config
- Expo/React Native config
- an explicit repo-owned preview file such as `capacitor.preview.json`, or a
  canonical `~/.capacitor` project preview capability

Avoid using the batch worktree `.capacitor/` artifact folder as checked-in
project configuration. Capacitor already uses `.capacitor/` inside worktrees for
generated claim, checkpoint, Done, and future preview artifacts.

### 2. Preview Session

A Preview Session is bound to a Work Batch, not the whole Project.

It records:

- batch id
- task ids covered
- worktree path
- preview kind
- command
- process id or app pid
- URL, app path, simulator id, or artifact path
- status
- build/log/screenshot artifact paths
- source git head
- started/completed timestamps

This is intentionally narrower than a runner. It starts and observes previews;
it does not schedule arbitrary task graphs.

### 3. Internal Preview Evidence

Done reports should grow a `preview` field, not replace `evidence`. Both fields
are protocol data, not the default user-facing UI:

```json
{
  "task_id": "task-123",
  "status": "done",
  "summary": "Removed the menu bar artifact in compact mode.",
  "evidence": [
    "Built the macOS preview app from the batch worktree.",
    "Captured screenshot showing the artifact no longer appears."
  ],
  "preview": {
    "required": true,
    "kind": "native_macos_app",
    "status": "ready_to_inspect",
    "session_id": "preview-abc",
    "artifacts": [
      {
        "type": "screenshot",
        "path": ".capacitor/work-batch-previews/preview-abc/after.png"
      },
      {
        "type": "build_log",
        "path": ".capacitor/work-batch-previews/preview-abc/build.log"
      }
    ]
  },
  "completed_at": "2026-05-27T12:00:00Z"
}
```

Rules:

- Done remains trusted by default for ordinary tasks.
- Visual/native UI tasks should be allowed to complete as `done`, but the card
  should show `Ready to inspect` when internal preview proof exists.
- If the task appears visual/native and no preview proof exists, Capacitor
  should show `Done claimed, preview missing` or reopen into a Checkpoint-like
  review state.
- Unresolve remains the correction path when the user sees the preview is wrong.

### 4. Preview Card UX

Keep the card simple:

```text
Typeface polish
Ready to inspect
2 done · 1 queued
Preview: macOS app built from batch worktree
```

Primary action:

- pending checkpoint: open checkpoint
- preview ready: open preview
- active work: open cockpit
- no live preview: view result or cockpit

Detail view:

- concise result
- preview rail or artifact panel
- before/after where available
- build/run status
- "Open Preview"
- "Looks good"
- "Still broken"
- "Ask for changes"
- proof details behind disclosure

This matches the existing checkpoint direction: lead with something a human can
decide from, then keep raw proof available internally.

## Preview Policies By Platform

### Web Policy

First broad adapter target.

Default behavior:

1. Detect a likely dev command.
2. Start it from the batch worktree with a Capacitor-assigned port.
3. Wait for health by reading stdout and probing HTTP.
4. Open a browser or in-app preview to the exact URL.
5. Capture at least one screenshot when possible.
6. Record command, cwd, pid, port, URL, and screenshot paths.

Failure copy:

```text
Preview could not start. Port or setup failed.
```

Do not silently fall back to a root-checkout server.

### Native macOS Policy

First proof spike because it is the immediate pain and the hardest identity
problem.

Default behavior:

1. Build from the batch worktree into a preview-specific output directory.
2. Prefer a stable preview target or scheme when the project supports it.
3. Launch by exact app path, not just bundle id.
4. Record app path, bundle id, pid, git head, and build log.
5. Capture screenshot when Accessibility/screen capture permission allows.
6. Surface "Ready to inspect" after launch.

Hard rule: a same-name, same-bundle-id app launched from the wrong checkout is
not acceptable preview proof.

For Capacitor itself, the preview slice should likely add:

```text
CapacitorPreview.app
com.petekp.capacitor.preview
```

Dynamic per-batch bundle ids are an option only after a spike proves they do not
break signing, preferences, app groups, or Launch Services behavior. The safer
first native path is a stable preview identity plus path, pid, worktree, and git
head proof.

### iOS Simulator Policy

Third target.

Default behavior:

1. Detect simulator-capable build command.
2. Use a default simulator if the project has one configured.
3. Install and launch.
4. Record simulator id, bundle id, app path, build log, and screenshot.

Do not start with physical device support.

### Electron/Tauri Policy

Desktop wrapper policy.

Default behavior:

1. Prefer dev mode for fast preview when the task affects UI.
2. Use package/build mode only when the task likely affects packaging,
   signing, app identity, installer behavior, or native shell behavior.
3. Record both the native process and the frontend server URL if present.

### Command/Artifact Policy

Default behavior:

1. Run or ingest the verification command/artifact path.
2. Present a concise result brief.
3. Avoid "Open Preview" copy unless there is a visual/live surface.
4. Keep raw output, logs, and generated files available as internal proof.

## Failure-Mode Ledger

| Failure | Likelihood | Impact | Policy |
|---|---:|---:|---|
| User opens root checkout build instead of batch worktree build | High for native | High | Every preview records and displays worktree path and git head; native preview launches by path/pid proof |
| Port collision starts a different web server | Medium | High | Capacitor allocates ports and verifies cwd/process before opening URL |
| Agent says visual work is done without preview proof | High | Medium | Done report accepts it but card shows preview missing for visual/native tasks |
| Native app shares bundle id/state with normal app | High | High | Prefer preview-specific bundle id/display name/state path |
| Build is too slow for every task | High | Medium | Preview is on-demand unless task class requires preview proof before Done |
| Physical device preview fails because of signing/network | High | Medium | Simulator first; device support explicit and later |
| Preview process leaks or keeps ports busy | Medium | Medium | Preview Session owns cleanup/stop action and records pid |
| Screenshot capture permission is missing | Medium | Low | Degrade to launch/build proof plus manual inspection |
| Agent modifies external services/migrations for preview | Medium | High | Preview capability can declare required services and trust boundaries |
| Multiple previews for same batch confuse the user | Medium | Medium | Show latest preview as primary, history behind disclosure |
| Preview capability inference chooses the wrong command | Medium | High | Treat inferred capabilities as editable/advisory; record command and cwd before claiming proof |
| Native preview identity changes break signing or preferences | Medium | High | Prefer a stable preview target first; dynamic identity requires a separate spike |

## Recommended Build Order

### Phase 1: Preview Status Contract

Add internal preview metadata to Done reports and Work Batch projection.

Acceptance:

- A Done report can say preview is ready, missing, failed, or not applicable.
- Work Batch cards can show "Ready to inspect" without inventing a new task
  state.
- Existing Done reports still decode.
- No build or launch automation yet.

### Phase 2: Capacitor Native macOS Preview Spike

Use Capacitor itself as the proof case. This comes before the general web
adapter because it tests the bug-prone path the user is already feeling: "the
worker says it fixed the native app, but I cannot inspect the batch worktree
build without manually rebuilding and risking the wrong app."

Acceptance:

- A Work Batch can build a preview app from its batch worktree.
- Capacitor launches the exact preview app, not the installed release app or the
  root debug app.
- The UI shows the app path/worktree/build head.
- The user can distinguish normal Capacitor from preview Capacitor at a glance.

### Phase 3: Web Preview Adapter

Add the first broadly reusable preview adapter after the native spike establishes
the preview/result model.

Acceptance:

- From a batch worktree, Capacitor can start a declared web preview command on
  a managed port.
- It opens the exact URL.
- It records cwd, pid, port, URL, log path, and screenshot path when available.
- It refuses to call a root-checkout server valid proof for a batch preview.

### Phase 4: Preview Result Surface

Give the operator a lightweight review packet.

Acceptance:

- The Work Batch opens a preview/result surface when preview is ready.
- The surface leads with outcome, preview status, risk, and action.
- Raw logs and diff are available but secondary.
- User can choose Looks Good, Still Broken, or Ask for Changes.

### Phase 5: Mobile/Desktop Wrapper Adapters

Add simulator and wrapper app support after the core model proves itself.

Acceptance:

- iOS simulator preview records simulator id and app bundle id.
- Electron/Tauri previews record native process and any frontend server.
- Failures are explained without asking users to understand CLI details.

## Non-Goals

- Do not build a general CI system.
- Do not replace native agent cockpits.
- Do not force approval for every Done task.
- Do not build a task DAG, runner, flow engine, or SaaS deploy workflow.
- Do not require users to configure every preview up front.
- Do not treat worktree isolation as security sandboxing.

## Open Questions

1. Should preview capabilities live in a repo-owned file such as
   `capacitor.preview.json`, in `~/.capacitor`, or both?
2. For macOS preview builds, should Capacitor mutate bundle ids dynamically, or
   require projects to define a stable preview target/scheme?
3. Should preview sessions be driven entirely from Swift, or should Rust own
   preview session persistence while Swift owns launch/build side effects?
4. How aggressively should Capacitor infer visual/native tasks from natural
   language versus letting Done reports declare preview requirements?
5. Should preview artifacts live in the batch worktree `.capacitor/` folder or
   canonical `~/.capacitor` storage with a mirror in the worktree?

## Recommendation

Build Preview Work as a small protocol and UI layer first, not as automation.

The first real implementation should be:

1. Extend Done reports and internal evidence to describe preview status.
2. Show `Ready to inspect` / `Preview missing` honestly.
3. Add a Capacitor-native macOS preview spike because it attacks the immediate
   pain and hardens app identity rules.
4. Add a web preview adapter because it gives fast proof of the portable model.

The durable product shape is:

```text
Task done -> Preview ready -> Open Preview -> Looks good / Still broken
```

The durable architecture shape is:

```text
Work Batch
  owns Batch Worktree
  owns Preview Session
  receives Claim / Checkpoint / Done / internal preview proof
  presents one operator-facing preview action
```

That keeps the user out of worktree/build/session plumbing while preserving the
local-first operator control plane that Capacitor is becoming.

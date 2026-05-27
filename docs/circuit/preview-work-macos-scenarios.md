# macOS Preview Work Scenario Ledger

Status: planning ledger
Date: 2026-05-27
Scope: Work Batch-scoped macOS preview builds and launches

## Bottom Line

macOS Preview Work is not mainly a build problem. It is an identity and trust
problem.

The user wants to know: "Am I looking at the exact app build from this Work
Batch?" Capacitor should answer that with a simple state and action:

```text
Ready to inspect
Open Preview
```

Everything else is internal proof: worktree path, git head, build command,
bundle id, app path, pid, launch time, logs, crash reports, and screenshot
artifacts.

The first implementation should prove one thing extremely well:

```text
Build the app from the batch worktree, launch that exact app by path, and never
present a root checkout, installed release app, or stale Debug app as preview.
```

## Source Grounding

### Confirmed In Capacitor

- Work Batches own isolated Batch Worktrees under
  `.capacitor/worktrees/<name>` (`apps/swift/Sources/Capacitor/Helpers/WorktreeService.swift:151`).
- The Work Batch Context Mirror records the batch id, batch name, project path,
  worktree path, Tasks, claim path, Done report path, and Checkpoint path
  (`apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:119`,
  `apps/swift/Sources/Capacitor/Models/WorkBatchTaskSession.swift:146`).
- Done reports currently carry `task_id`, `status`, `summary`, `evidence`, and
  `completed_at`, but no structured preview field
  (`apps/swift/Sources/Capacitor/Models/WorkBatchCompletionReport.swift:93`).
- The current debug app already has a distinct bundle id and visible name:
  `com.capacitor.app.debug`, `Capacitor Debug`
  (`scripts/dev/restart-app.sh:360`).
- The debug launch path already avoids inherited host environment leakage by
  launching with a sanitized environment (`scripts/dev/restart-app.sh:381`,
  `scripts/dev/restart-app.sh:794`).
- The manual-test guard already treats wrong app identity as unsafe and checks
  running process path, frontmost app path, and stale build freshness
  (`scripts/dev/check-terminal-activation-state.sh:88`,
  `scripts/dev/check-terminal-activation-state.sh:135`,
  `scripts/dev/check-terminal-activation-state.sh:168`).
- Swift owns presentation, orchestration, terminal drivers, and macOS side
  effects; Rust owns runtime semantics and persistence
  (`docs/ARCHITECTURE.md:18`).

### Confirmed From Apple/Tooling Docs

- `CFBundleIdentifier` uniquely identifies a bundle; Apple notes that the OS
  uses it for preferences, Launch Services lookup, and signature validation.
  Source: https://developer.apple.com/documentation/BundleResources/Information-Property-List/CFBundleIdentifier.
- Apple's Info.plist reference says each distinct app/bundle should have a
  unique bundle id, and Launch Services can use the bundle id to locate the
  first app it finds for a role. Source:
  https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/CoreFoundationKeys.html.
- Launch Services maintains a database of application and document/URL handling
  information from bundle Info.plists. Source:
  https://developer.apple.com/library/archive/documentation/Carbon/Conceptual/LaunchServicesConcepts/LSCConcepts/LSCConcepts.html.
- `LSUIElement` marks an app as an agent app. Source:
  https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/LaunchServicesKeys.html.
- Xcode build settings include `CONFIGURATION_BUILD_DIR`, the build products
  base path, and other build-location settings. Source:
  https://developer.apple.com/documentation/xcode/build-settings-reference.
- UserDefaults stores app-specific settings, and Apple's defaults guide states
  that the preference database file name is based on the app bundle identifier.
  Sources: https://developer.apple.com/documentation/foundation/nsuserdefaults
  and
  https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/AboutPreferenceDomains/AboutPreferenceDomains.html.
- App Sandbox restricts access to system resources and user data through
  entitlements; sandboxed apps get containers. Sources:
  https://developer.apple.com/documentation/Security/app-sandbox and
  https://developer.apple.com/documentation/Xcode/configuring-the-macos-app-sandbox.
- Apple's unified logging docs describe system-level log capture for debugging,
  and Xcode docs describe using crash reports and device logs to diagnose app
  issues. Sources: https://developer.apple.com/documentation/os/logging and
  https://developer.apple.com/documentation/xcode/diagnosing-issues-using-crash-reports-and-device-logs.
- Apple's code-signing docs note that manual signing can use `codesign`, that
  entitlements are supplied with `--entitlements`, and that bundled code does
  not need an explicit signing identifier because `codesign` defaults to the
  bundle id. Sources:
  https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Procedures/Procedures.html
  and
  https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac.

## Product Policy

- Evidence is internal. Users should see status, result, preview, risk, and
  action.
- Preview identity must be proven before `Ready to inspect` appears.
- Launching the wrong app is worse than refusing to preview.
- The first native slice should prefer a stable preview target/name/bundle id,
  not dynamic per-batch bundle ids.
- Per-batch simultaneous native previews are allowed only when Capacitor can
  prove identity and state isolation.
- Preview Work starts on demand. Done remains trusted by default, but UI/native
  work may show `Preview missing` until a preview exists.
- Swift should own build/launch/screenshot/macOS side effects. Rust may later
  own persisted preview session records if they become canonical runtime state.

## Scenario Ledger

Severity means impact if Capacitor mishandles the case.

| ID | Scenario | Severity | Intended user behavior | Detection and internal proof | Policy / acceptance criteria |
|---|---|---:|---|---|---|
| MAC-01 | Batch preview accidentally launches `/Applications/Capacitor.app` | Critical | Show `Preview failed: wrong app` | Compare launched process path to expected app path | Never mark ready if process path does not match the batch preview artifact |
| MAC-02 | Batch preview launches root checkout `CapacitorDebug.app` instead of batch worktree build | Critical | Show `Preview identity uncertain` | Record expected worktree path, artifact path, git head, pid, and process path | The preview artifact must be built from the batch worktree and launched by exact path |
| MAC-03 | Same bundle id exists in release, debug, and preview apps | High | Show `Preview identity conflict` | Inspect `CFBundleIdentifier` from the built app and compare known running apps | First slice should use a stable preview bundle id distinct from release/debug |
| MAC-04 | Same visible app name for normal and preview build | High | Preview app is visibly labeled | Inspect `CFBundleName` / `CFBundleDisplayName` | Preview display name must distinguish the build, e.g. `Capacitor Preview` |
| MAC-05 | Launch Services foregrounds an existing app with the same bundle id | High | Do not claim preview is open unless pid/path match | Use launch result plus process path/pid verification | Prefer launch by exact path and verify the resulting process, not just app name/bundle id |
| MAC-06 | Launch Services cache points to a stale app path | High | Show failure with clear recovery | Compare expected artifact path to frontmost/running process path | Wrong path is a hard failure; never silently accept Launch Services result |
| MAC-07 | `open -a` or app-name launch picks the wrong app | High | Avoid this path in normal preview | Command audit: launch mode is app path, not app name | `Open Preview` for macOS must use exact app path or a proven equivalent |
| MAC-08 | User already has a release app running | Medium | Preview can still open if identity is distinct | List running Capacitor-family processes | Coexistence is allowed only if preview id/path/name are distinct |
| MAC-09 | User already has a Debug app running | Medium | Preview can still open if identity is distinct | List running debug and preview processes | Debug app is not valid preview proof for a batch |
| MAC-10 | Existing preview process from older build is still running | High | Show `Preview stale` or relaunch | Compare pid launch time, app path, git head, build timestamp | Kill/relaunch only with a preview-owned pid; otherwise explain and ask |
| MAC-11 | Preview app path was deleted or rebuilt while running | Medium | Keep current preview marked running but warn stale-on-disk | Compare running process path and current artifact checksum/timestamp | Do not confuse running preview with rebuilt artifact |
| MAC-12 | Multiple Work Batches build same stable preview bundle id | High | Allow one active native preview per preview identity at first; explain conflict | Compare active preview sessions by bundle id and preview kind | First slice should serialize same-bundle native previews or require stop/relaunch |
| MAC-13 | Multiple Work Batches need simultaneous native previews | High | Allow only when identities/state are isolated | Record bundle id, path, pid, state root for each preview | Later slice may use per-batch display names/bundle ids after signing/state spike |
| MAC-14 | Dynamic per-batch bundle id breaks signing or entitlements | High | Fall back to stable preview identity and explain | Codesign/build output contains bundle id/signing errors | Dynamic ids require a separate spike and explicit project support |
| MAC-15 | App uses UserDefaults and preview shares release/debug settings | Medium | Preview opens, but card shows shared-state risk | Compare bundle id and known state domains | Stable distinct preview bundle id is minimum; per-batch defaults isolation is later |
| MAC-16 | `cfprefsd` caches old UserDefaults after bundle id or defaults reset | Low | If reset requested, report restart/cache flush need | Defaults read/write mismatch after reset | Do not promise clean state unless a reset/flush policy ran |
| MAC-17 | App writes to Application Support/Caches by app name instead of bundle id | Medium | Show shared-state warning if detected/configured | Project preview config declares state paths or scan common paths | Preview capability should support explicit state isolation paths |
| MAC-18 | App uses Keychain items shared across preview/release | Medium | Show shared-credential risk | Preview config marks keychain/app-group usage | Do not try to isolate Keychain implicitly in first slice |
| MAC-19 | App uses App Groups or shared containers | High | Require explicit preview capability | Inspect entitlements if present | Shared containers are a trust boundary; do not infer safe isolation |
| MAC-20 | Sandboxed app container differs by bundle id | Medium | Preview may show empty/new app state | Read entitlements and bundle id | Treat clean sandbox container as expected, not data loss |
| MAC-21 | Sandboxed preview lacks entitlement needed for local server/file access | High | Show `Preview failed: permission denied` | Build/run logs and sandbox denial logs | Surface concise failure; keep log detail internal |
| MAC-22 | Preview app requires Accessibility permission | Medium | Show `Preview needs permission` | Detect TCC/AX failure from app or screenshot automation | Do not block all preview; explain missing permission |
| MAC-23 | Screenshot capture requires Screen Recording permission | Low | Preview can still open; screenshot proof missing | Screenshot command/API fails with permission-like error | Degrade to launch proof and manual inspection |
| MAC-24 | Apple Events/System Events automation permission is denied | Medium | Preview may open but focus/screenshot checks degrade | AppleScript/automation failure | Do not mark wrong-build safe from missing automation; show identity uncertain if path cannot be proven |
| MAC-25 | App is a menu bar/agent app (`LSUIElement=true`) | Medium | Open preview and show `No main window detected` | Inspect `LSUIElement`; observe windows | Ready can mean "process launched"; user copy must not promise a visible window |
| MAC-26 | App launches background helper then exits | Medium | Show helper running if expected, failed if not | Track parent pid, child/helper process, exit code | Preview capability must declare expected long-lived process shape |
| MAC-27 | App launches with no windows because it restores hidden/minimized state | Medium | Offer `Bring Preview Forward` or state reset | Running process exists, no visible window | Prefer distinct preview state; otherwise provide frontmost/focus action |
| MAC-28 | App has multiple windows and wrong one comes forward | Low | User still gets exact preview app | Window list and app pid | Do not overfit first slice; app identity matters more than specific window |
| MAC-29 | App crashes on launch | High | Show `Preview crashed` | Exit status, crash report, unified log snippet | Capture crash/log path internally and do not present as ready |
| MAC-30 | App hangs during launch | Medium | Show `Preview still launching` then timeout | Launch timeout, no window/no ready signal | Timeout becomes `Preview failed` with retry |
| MAC-31 | App is quarantined or blocked by Gatekeeper | High | Show `Preview blocked by macOS` | Launch output, `spctl`/codesign failure if checked | Build/sign policy must avoid quarantine for generated local preview apps |
| MAC-32 | Ad-hoc signing works locally but hides entitlement/signing issue | Medium | Show signing mode in details/debug | Record signing identity/mode | First slice can ad-hoc sign for local preview, but not call it distribution proof |
| MAC-33 | Embedded helper binary or framework is unsigned/wrongly signed | High | Show `Preview build failed` | Codesign output, launch crash/logs | Preview build must sign/copy nested code coherently |
| MAC-34 | Framework rpath points to root checkout or missing dylib | High | Show `Preview build failed` or `Preview crashed` | `otool`/launch error/logs when available | Build script must make app self-contained enough for local launch |
| MAC-35 | Capacitor-specific Rust core dylib is stale | High | Show stale build or rebuild | Compare source mtimes and bundled dylib timestamp | Reuse the existing stale-build guard pattern for preview artifacts |
| MAC-36 | SwiftPM executable exists but no `.app` bundle exists | Medium | Show `Preview unavailable for native app until bundle recipe exists` | No app bundle artifact after build | Preview capability must define bundling recipe for SwiftPM-only apps |
| MAC-37 | Xcode workspace has multiple schemes/apps | Medium | Ask only if inference is unsafe; otherwise use configured capability | Detect multiple `.xcodeproj`/workspace schemes | Prefer explicit preview capability over guessing |
| MAC-38 | Xcode DerivedData reuses stale build products across worktrees | High | Build uses preview-specific DerivedData/output path | Record build dir and app path | Must isolate build products per Work Batch or per preview session |
| MAC-39 | Build output is correct but app loads resources from root checkout | Medium | Show shared-resource risk if detected | Launch env/cwd/resource paths when known | Preview should launch with worktree cwd and record env/cwd |
| MAC-40 | Build command inherits Codex/Capacitor environment | Medium | Preview behaves like normal user shell/app | Record sanitized env policy | Native preview builds/launches should use a narrow, intentional environment |
| MAC-41 | Preview build triggers Sparkle/update checks | Medium | Preview suppresses updater by config when possible | Inspect Info.plist/update keys or app config | Preview mode should disable update checks if project supports it |
| MAC-42 | App sends notifications/sounds from preview build | Low | Label notification source as preview where possible | Bundle display name and notification settings | Distinct display name reduces surprise |
| MAC-43 | App opens login items/background services | High | Require checkpoint or explicit preview capability | Entitlements/known helper config | Preview should not install persistent background items by default |
| MAC-44 | App starts a local server/port that collides with another preview | Medium | Show port conflict and retry if safe | Track preview-owned ports/processes | Preview session owns port/process cleanup |
| MAC-45 | App depends on external services or real credentials | High | Show trust boundary before launching if likely risky | Preview capability declares external services/credentials | Do not hide costly/external side effects behind `Open Preview` |
| MAC-46 | App writes database migrations or destructive local data changes | High | Require checkpoint unless preview sandbox/state is explicit | Detect migration commands/config where possible | Trust boundary: preview should not surprise the user |
| MAC-47 | Worker claims visual task Done with no preview | Medium | Card shows `Preview missing`, not just Done | Done report lacks preview metadata for visual/native task | User can still trust Done, but UI exposes missing preview affordance |
| MAC-48 | Preview starts before task changes are committed | Low | Preview still valid for worktree state | Record git head plus dirty status | Internal proof must include dirty status, not only commit hash |
| MAC-49 | Worktree has untracked generated files needed for build | Medium | Preview may be valid but not reproducible | Record dirty/untracked status and build log | Result brief can show `Uncommitted preview build` in details |
| MAC-50 | Worktree is deleted while preview is active | Medium | Existing preview remains inspectable but no rebuild | Process path and worktree existence check | Show stale/source-missing state, not ready-for-current-work |
| MAC-51 | User manually opens/edits the preview app outside Capacitor | Low | Capacitor reflects what it can prove | Compare known preview session pid/path to running state | Manual intervention is allowed; trust only recorded proof |
| MAC-52 | User clicks Work Batch while preview is ready | Medium | Primary action opens preview/result, secondary opens cockpit | Batch state has preview-ready flag | Do not hide the agent cockpit; preview is for inspection |
| MAC-53 | User clicks Work Batch while checkpoint is waiting | Medium | Checkpoint wins over preview | Batch has active checkpoint | Needs You remains stronger than Ready to inspect |
| MAC-54 | Preview fails but agent session is still healthy | Low | Show retry/open cockpit actions | Preview status failed, cockpit binding healthy | Failure does not imply task/session failure |
| MAC-55 | Preview succeeds but user says "Still broken" | Medium | Reopen task or append feedback to batch context | User action creates correction/Unresolve artifact | This is the correction path, not a failed approval gate |
| MAC-56 | Preview artifact contains privacy-sensitive screenshots/logs | Medium | Keep proof internal by default | Artifact type and storage policy | Do not surface raw artifacts unless user opens details |
| MAC-57 | Crash/log capture includes secrets | High | Redact before displaying; store carefully | Telemetry redaction and artifact classification | Raw proof is internal and should be redacted for user display |
| MAC-58 | Preview app accessibility/focus automation is flaky | Medium | Prefer proven app identity over focus perfection | Process path/pid proof succeeds but frontmost check fails | Ready can mean launch succeeded; focus failure gets its own action |
| MAC-59 | macOS Spaces/fullscreen hides preview window | Low | Offer `Bring Preview Forward` | Running app exists, frontmost/window not visible | Do not relaunch unnecessarily |
| MAC-60 | App does not support simultaneous instances even with `open -n` | Medium | Show `Preview already running` | Second launch exits or foregrounds first pid | Capability can declare single-instance behavior |

## First Slice Acceptance Criteria

The first macOS preview slice is done when these are all true:

1. A Work Batch can request a macOS preview for its Batch Worktree.
2. Capacitor builds from that Batch Worktree into a preview-specific artifact
   path.
3. Capacitor launches the exact app artifact by path.
4. Capacitor records app path, bundle id, display name, pid, launch time,
   worktree path, git head, dirty state, build command, build log path, and
   launch status as internal proof.
5. The user-facing card says only what matters: `Preview building`,
   `Ready to inspect`, `Preview failed`, or `Preview missing`.
6. If identity cannot be proven, Capacitor refuses to show `Ready to inspect`.
7. Existing release/debug/root-checkout apps are never accepted as batch preview
   proof.
8. Raw logs, build commands, screenshots, and crash artifacts stay behind
   disclosure/debug surfaces.
9. The user can still open the Work Batch cockpit separately.
10. A failed preview does not incorrectly mark the Task or agent session failed.

## Open Policy Questions

1. Should Capacitor require projects to define a stable preview target, or infer
   a preview app by patching/copying existing debug bundles?
2. For Capacitor itself, should the preview app be `Capacitor Preview` with a
   stable `com.capacitor.app.preview` id, or should each Work Batch eventually
   get a per-batch id?
3. Where should canonical Preview Session records live: Swift-owned app state,
   Rust-owned runtime state, or `~/.capacitor` with a worktree mirror?
4. Should preview build commands be allowed to run automatically after Done, or
   only on user demand?
5. How much state isolation is required before allowing multiple simultaneous
   native previews?
6. Should screenshot capture be attempted by default, or only after the user
   opens the preview?
7. How should Capacitor detect visual/native Tasks that deserve `Preview
   missing` rather than plain Done?

## Recommendation

Start conservative.

The first macOS preview implementation should support one active preview per
preview identity. A Work Batch can own that preview while it is active, but
Capacitor should not promise arbitrary simultaneous native previews yet. It
should use a stable, visibly distinct preview app identity, exact app-path
launching, strict path/pid verification, isolated build output, and internal
proof records.

After that works, the next spike should decide whether simultaneous previews
need per-batch bundle ids, per-batch state roots, or simply serialized native
preview sessions with explicit "stop current preview" behavior.

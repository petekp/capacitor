# Execution Spec: Rebuild UX — Diff + Banner

## Change 1: Manifest Schema Extension
**File:** `apps/swift/Sources/Capacitor/Models/DelegationReviewManifest.swift`

Add `swiftChanges: Bool?` field to `DelegationReviewManifest`:
```swift
let swiftChanges: Bool?
```
With CodingKey `swift_changes`. Default to `nil` (backwards compatible — existing manifests
without the field decode as `nil`).

## Change 2: Worker Prompt Update
**File:** `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`

In both `buildInitialPrompt` and `buildResumePrompt`, add to the manifest schema
description:
```
"swift_changes": true  // set to true if any .swift files were modified
```
Add a requirement line: "If you modify any `.swift` files, set `swift_changes: true` in the manifest."

## Change 3: Diff Section in Review Window
**File:** `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift`

Add a "CHANGES" section below the ARTIFACTS section in `contentPane`. This section:
1. Runs `git diff --stat HEAD` in the worktree (`delegation.worktreePath`) asynchronously
2. Shows the stat summary (files changed, insertions, deletions)
3. Has a "Show Full Diff" disclosure that expands to the full `git diff HEAD` output
4. Renders in monospace, text-selectable, scrollable
5. Only shown when the diff is non-empty

Implementation: a `@State private var diffStat: String = ""` and
`@State private var fullDiff: String = ""` loaded via `Task` alongside `loadReviewArtifacts()`.
Use `Process` to run `git diff` — same pattern as elsewhere in the codebase.

## Change 4: Swift Changes Banner
**File:** `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift`

When `manifest?.swiftChanges == true`, show a dismissible banner between the header
and the brief:
```
[info icon] This milestone includes Swift UI changes. The running app
reflects the previous build.
[Copy rebuild command]  [Dismiss]
```
The copy button copies `./scripts/dev/restart-alpha-stable.sh` to the pasteboard.
Dismissed state stored as `@State private var bannerDismissed: Bool = false`.
Banner reappears on milestone change (reset in `loadReviewArtifacts`).

## Change 5: Tests
**File:** `apps/swift/Tests/CapacitorTests/DelegationReviewManifestTests.swift` (new or existing)

- Test that manifests with `swift_changes: true` decode correctly
- Test that manifests without `swift_changes` field decode with `nil` (backwards compat)
- Test that manifests with `swift_changes: false` decode correctly

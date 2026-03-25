# Review Iteration — Implementation Plan

**Spec:** `docs/superpowers/specs/2026-03-19-review-iteration-design.md`
**Date:** 2026-03-19
**Status:** Ready for execution

## Phase 1: Numbered Milestones + Reconciliation

Phase 1 delivers the core review iteration loop. After requesting changes, the worker produces a new numbered milestone that returns for re-review. The existing inline `DelegationReviewView` receives the dynamic milestone ID and works without changes.

### Slice 1.1 — Split WorkerPaths and add milestone scanning

**Goal:** Replace the hardcoded `Constants.milestoneID = "01"` with dynamic milestone directory scanning. Split `WorkerPaths` so worker-root paths and milestone-specific paths are computed independently.

**File:** `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`

**Changes:**

1. **Defer `Constants.milestoneID` removal to Slice 1.3** — removing it here would break compilation before Slices 1.2-1.3 replace all usages. Slices 1.1-1.3 form a single atomic unit; the constant is removed only after all callsites are updated.

2. **Split `WorkerPaths` struct** into two levels:
   ```swift
   private struct WorkerRootPaths {
       let workerRoot: URL
       let milestonesRoot: URL        // .../milestones/
       let statusPath: URL
       let completionMarkerPath: URL
       let launchPromptPath: URL
       let resumePromptPath: URL
   }

   private struct MilestonePaths {
       let directory: URL             // .../milestones/01/
       let briefPath: URL
       let manifestPath: URL
       let decisionJSONPath: URL
       let decisionMarkdownPath: URL
       let sentinelPath: URL          // .../milestones/01/.review-ready
   }
   ```

3. **Add `workerRootPaths(projectPath:workerID:)` function** — returns `WorkerRootPaths` (replaces the worker-root portion of `workerPaths()`).

4. **Add `milestonePaths(milestonesRoot:milestoneID:)` function** — returns `MilestonePaths` for a specific milestone ID.

5. **Add `nextMilestoneID(milestonesRoot:)` function:**
   - Scans `milestonesRoot` for numeric subdirectories
   - Parses each directory name as Int (ignores non-numeric like `.DS_Store`)
   - Returns `String(format: "%02d", maxID + 1)`
   - Returns `"01"` for empty directory
   - Numeric sort, not lexicographic

6. **Add `activeMilestoneID(milestonesRoot:)` function:**
   - Scans `milestonesRoot` for numeric subdirectories (same parse logic)
   - Sorts numerically, iterates from highest
   - Returns the highest-numbered directory lacking `decision.json`
   - Returns `nil` if all milestones have decisions (worker is working between milestones)

7. **Keep a backward-compat `WorkerPaths` typealias or adapter** so callers that need both root and milestone paths can get them together. This minimizes churn in the first slice — callers that need the split will be updated in subsequent slices.

8. **Callsite inventory** — every function referencing `WorkerPaths` or `workerPaths()`:
   | Callsite | Line | Needs |
   |----------|------|-------|
   | `startDelegation()` | ~305 | Root + milestone "01" paths for initial prompt, dirs, launch prompt |
   | `submitReviewDecision()` | ~432 | Root + current milestone paths (updated in Slice 1.3) |
   | `reconcile(delegation:)` | ~502 | Root + active milestone scan (updated in Slice 1.2) |
   | `buildInitialPrompt()` | ~908 | Root + milestone "01" paths for prompt text (updated in Slice 1.3) |
   | `buildResumePrompt()` | ~953 | Root + current milestone + next milestone (updated in Slice 1.3) |
   | `createWorkerDirectories()` | ~874 | Root + milestone dirs (updated in Slice 1.4) |
   | `writeReviewDecision()` | ~879 | Milestone paths only (updated in Slice 1.4) |

   **IMPORTANT: Slices 1.1-1.4 are a single commit.** The shim exists only as a mechanical aid during development — it is never deployed independently. The shim computes `WorkerRootPaths` + `MilestonePaths(milestoneID: "01")` and exposes all properties flat (matching the current `WorkerPaths` layout). Each subsequent slice migrates its callers to the split types, and the shim is removed in Slice 1.4. Since all slices land atomically, there is no intermediate state where the reconciler returns dynamic milestone IDs but `submitReviewDecision()` still uses the hardcoded shim.

**Verification:**
```bash
swift test --package-path apps/swift --filter DelegationLoopManagerTests
```

### Slice 1.2 — Update reconciliation to scan milestone directories

**Goal:** Replace the fixed-path checks in `reconcile()` with milestone directory scanning and sentinel file validation.

**File:** `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`

**Changes to `reconcile(delegation:)` (lines 501-571):**

1. **Preserve the `guard delegation.status == "working"` gate** (line 519) — this prevents re-scanning milestones for delegations already in `review_needed` status. Critical: do not remove this during the rewrite.

2. **Completion check unchanged** — `completion.json` at worker root stays the same.

3. **Replace the fixed-path brief/manifest/decision checks** with:
   ```
   let rootPaths = workerRootPaths(...)
   guard let activeID = activeMilestoneID(milestonesRoot: rootPaths.milestonesRoot) else {
       return  // All milestones decided — worker is working
   }
   let milestone = milestonePaths(milestonesRoot: rootPaths.milestonesRoot, milestoneID: activeID)
   ```

3. **Add sentinel file check:** Instead of checking `briefPath` and `manifestPath` individually, check for `.review-ready` sentinel:
   ```
   guard fileManager.fileExists(atPath: milestone.sentinelPath.path) else {
       return  // Worker still writing
   }
   ```

4. **Add manifest JSON validation:** Before triggering `review_ready`, read `manifest.json` and verify it parses as valid JSON. If it doesn't parse, skip (treat as incomplete):
   ```
   guard let manifestData = fileManager.contents(atPath: milestone.manifestPath.path),
         (try? JSONSerialization.jsonObject(with: manifestData)) != nil
   else {
       return  // Corrupt or incomplete manifest
   }
   ```

5. **Pass dynamic milestone ID** in the `review_ready` mutation (replacing `Constants.milestoneID`).

6. **Pass dynamic paths** — construct `briefPath` and `manifestPath` from the active milestone's paths.

**Key invariant:** At most one milestone at a time lacks `decision.json`. This is enforced by the flow — workers only create milestone N+1 after the user decides milestone N.

**Verification:**
```bash
swift test --package-path apps/swift --filter DelegationLoopManagerTests
```

### Slice 1.3 — Update submitReviewDecision and buildResumePrompt

**Goal:** When the user submits `request_changes`, the resume prompt instructs the worker to produce a new milestone (not finalize). Decision writes to the current milestone directory.

**File:** `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`

**Changes to `submitReviewDecision()` (lines 405-493):**

1. **Compute paths dynamically:**
   ```
   let rootPaths = workerRootPaths(projectPath: project.path, workerID: delegation.workerId)
   let currentMilestoneID = delegation.currentReview?.milestoneId ?? "01"
   let milestone = milestonePaths(milestonesRoot: rootPaths.milestonesRoot, milestoneID: currentMilestoneID)
   ```

2. **Staged decision write** — Write as `decision-pending.json` first, not `decision.json`. Only rename to `decision.json` after Claude launch succeeds. If Claude launch fails, delete the pending file. This preserves the spec's immutability guarantee: milestones with `decision.json` are permanently decided, and the reconciler won't skip an undecided milestone due to a half-committed decision.
   ```swift
   // Before Claude launch:
   try writeReviewDecision(decision:note:to:milestone, staged: true)  // writes decision-pending.json
   // After successful Claude launch:
   try fileManager.moveItem(at: milestone.pendingDecisionPath, to: milestone.decisionJSONPath)
   // On launch failure (catch block):
   try? fileManager.removeItem(at: milestone.pendingDecisionPath)
   ```
   Add `pendingDecisionPath` to `MilestonePaths` (`.../decision-pending.json`).
   The reconciler and `activeMilestoneID()` check only `decision.json`, so a pending file is invisible to them.

3. **For request_changes:** Compute `nextMilestoneID` and pass it to `buildResumePrompt()`.

4. **For approve:** No next milestone needed.

**Changes to `buildResumePrompt()` (lines 953-988) — full rewrite:**

The function signature gains parameters: `rootPaths: WorkerRootPaths`, `currentMilestonePaths: MilestonePaths`, and optionally `nextMilestoneID: String?` (non-nil only for request_changes).

**After approve:**
- Requirements stay: finalize, update status, write completion marker, exit
- "Do not open another review checkpoint" stays

**After request_changes:**
- Requirement 4 changes: "Address the requested delta and produce a new milestone"
- Requirement 5 inverts: "You MUST produce a new review checkpoint in milestones/{next}/"
- Requirements 7-8 change: no completion marker. The worker still exits, but via the milestone path (write new checkpoint → exit), not the completion path (write completion.json → exit)
- New requirements: write `brief.md` and `manifest.json` to `milestones/{next}/`, then write `.review-ready` sentinel, then exit
- Explicit write ordering instruction: "Write brief.md, then manifest.json, then touch .review-ready to signal completion. Exit after writing the sentinel."

**Changes to `buildInitialPrompt()` (lines 908-951) — signature also changes:**

The function currently takes `paths: WorkerPaths`. It must change to take `rootPaths: WorkerRootPaths` + `milestonePaths: MilestonePaths` so it can reference both status path (root) and sentinel path (milestone). `startDelegation()` is updated to compute both and pass them.

1. Update to reference sentinel file:
   ```
   6. Before stopping, write (in this order):
      - {briefPath}
      - {manifestPath}
      - {sentinelPath}  (empty file — signals milestone is complete)
   ```

2. Update milestone_id in manifest instructions to use the dynamic ID.

**Verification:**
```bash
swift test --package-path apps/swift --filter DelegationLoopManagerTests
cargo test -p capacitor-core
```

### Slice 1.4 — createWorkerDirectories and writeReviewDecision updates

**Goal:** Adapt helper functions to the new path structure.

**File:** `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`

**Changes:**

1. **`createWorkerDirectories()`** — takes `WorkerRootPaths` + `MilestonePaths` or just creates directories as needed. The worker root and current milestone directory both need to exist.

2. **`writeReviewDecision()`** — takes `MilestonePaths` instead of `WorkerPaths`. Writes `decision.json` and `decision.md` to the milestone directory.

**Verification:**
```bash
swift test --package-path apps/swift --filter DelegationLoopManagerTests
```

### Slice 1.5 — Tests

**Goal:** Comprehensive test coverage for the new milestone scanning and iteration logic.

#### Rust test (new)

**File:** `core/capacitor-core/tests/delegation_contract.rs`

**New test: `delegation_multi_round_review_iteration`**
- Start → ReviewReady("01") → Resume(request_changes) → ReviewReady("02") → Resume(approve) → Complete
- Validates the reducer handles the iteration cycle: milestone ID changes, `current_review` clears on Resume, repopulates on ReviewReady with new ID
- Validates snapshot at each step

#### Swift tests (new)

**File:** `apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift`

**New tests:**

1. **`testNextMilestoneIDReturns01ForEmptyDirectory`**
   - Create empty milestones dir → assert returns "01"

2. **`testNextMilestoneIDReturnsNextAfterExistingMilestones`**
   - Create dirs `01/`, `02/` with `decision.json` → assert returns "03"

3. **`testNextMilestoneIDIgnoresNonNumericEntries`**
   - Create dirs `01/`, `.DS_Store`, `temp/` → assert returns "02"

4. **`testActiveMilestoneIDReturnsHighestUndecided`**
   - Create `01/` with `decision.json`, `02/` without → assert returns "02"

5. **`testActiveMilestoneIDReturnsNilWhenAllDecided`**
   - Create `01/` and `02/` both with `decision.json` → assert returns nil

6. **`testReconcileDetectsNewMilestoneWithSentinel`**
   - Create `01/decision.json`, `02/brief.md`, `02/manifest.json`, `02/.review-ready`
   - Run reconcile → assert `review_ready` mutation with milestoneId "02"

7. **`testReconcileSkipsMilestoneWithoutSentinel`**
   - Create `02/brief.md`, `02/manifest.json` (no `.review-ready`)
   - Run reconcile → assert no `review_ready` mutation

8. **`testReconcileSkipsMilestoneWithInvalidManifest`**
   - Create `01/brief.md`, `01/manifest.json` (invalid JSON), `01/.review-ready`
   - Run reconcile → assert no `review_ready` mutation

9. **`testResumePromptBranchesOnDecisionType`**
   - Call `buildResumePrompt()` with `approve` → assert contains "completion marker"
   - Call `buildResumePrompt()` with `requestChanges` → assert contains next milestone path, does NOT contain "completion marker"

10. **`testFullIterationCycle`** (integration)
    - Start delegation
    - Create milestone 01 artifacts + sentinel on disk
    - Reconcile → verify review_ready("01")
    - Submit request_changes → verify resume mutation, verify resume prompt references milestone 02
    - Create milestone 02 artifacts + sentinel on disk
    - Reconcile → verify review_ready("02")
    - Submit approve → verify resume mutation, verify resume prompt references completion

11. **`testResumeFailurePreservesDecisionAndRestoresReview`**
    - Submit request_changes with a Claude launcher that throws
    - Verify: `review_ready` mutation is re-fired with the correct milestone ID
    - Verify: `decision.json` remains on disk (decision not lost)

12. **`testResumePromptFileContainsExpectedContent`**
    - Submit request_changes → read the written `resume-prompt.md` file
    - Assert: contains next milestone path, contains ".review-ready" sentinel instruction
    - Assert: does NOT contain "completion marker" or "do not open another review checkpoint"

13. **`testStagedDecisionCleanupOnResumeFailure`**
    - Submit request_changes with a Claude launcher that throws
    - Verify: `decision-pending.json` is deleted (not left on disk)
    - Verify: `decision.json` does NOT exist (spec immutability preserved)
    - Verify: `review_ready` mutation is re-fired with the correct milestone ID

Note: The spec's "malformed manifest graceful degradation" test (spec test case 8) is deferred to Slice 2.5 because `DelegationReviewManifest` is `private` in `DelegationReviewView.swift` until Slice 2.2 extracts it to a shared file.

**Verification:**
```bash
swift test --package-path apps/swift --filter DelegationLoopManagerTests
cargo test -p capacitor-core --test delegation_contract
```

---

## Phase 2: Standalone Review Window

Phase 2 replaces the inline `DelegationReviewView` with a dedicated macOS window optimized for deep artifact review.

### Slice 2.1 — Window scene registration

**Goal:** Register a new `Window(id: "delegation-review")` scene in the SwiftUI app.

**Files:**
- `apps/swift/Sources/Capacitor/App.swift` — add Window scene
- `apps/swift/Sources/Capacitor/Models/AppState.swift` — add review window state (active project/delegation for review)

**Changes:**

1. **Add Window scene in `App.swift`** after the Settings scene:
   ```swift
   Window("Delegation Review", id: "delegation-review") {
       DelegationReviewWindow()
           .environment(appState)
   }
   .defaultSize(width: 900, height: 650)
   .windowResizability(.contentMinSize)
   .suppressedFromWindowMenu()
   ```

2. **Add state in `AppState`** to track which project/delegation the review window should display. Use a dedicated struct (not a tuple — tuples aren't `Equatable` in SwiftUI observation):
   ```swift
   struct ReviewWindowTarget: Equatable {
       let project: Project
       let workerID: String
   }
   var reviewWindowTarget: ReviewWindowTarget?
   ```
   The review window reads live delegation state from `appState.delegationState(for:)` using the stored `workerID`, rather than freezing a snapshot at open time. This ensures session ID updates during review are reflected when submitting decisions.

3. **Window opening uses `@Environment(\.openWindow)`** — `openWindow(id:)` is a SwiftUI view-environment action, not callable from `AppState` directly. The pattern is:
   - `AppState` exposes `setReviewWindowTarget(_:)` to store the target
   - The view that triggers the open (project card tap handler) uses `@Environment(\.openWindow)` to open the window after setting the target
   - The `DelegationReviewWindow` view reads `appState.reviewWindowTarget` on appear

4. **Submission flow for standalone window:** The existing `AppState.submitDelegationReview()` unconditionally calls `showProjectList()` after success, which navigates the main HUD. The review window needs a separate code path:
   - Extract the core logic (call `delegationLoopManager.submitReviewDecision()`) into a shared helper
   - The HUD path continues to call `showProjectList()` after
   - The window path dismisses via `@Environment(\.dismissWindow)` instead
   - Or: add a `source` parameter to `submitDelegationReview()` that controls post-submission behavior

5. **AX identifiers:** Reuse existing `AccessibilityIdentifiers` for review actions (`ax.delegation-review.approve`, etc.) so the AX automation verifier continues to work. Add new identifiers for review-window-specific elements (content pane, decision rail).

**Verification:**
```bash
./scripts/dev/restart-alpha-stable.sh
```

### Slice 2.2 — Zen layout: scrollable content pane

**Goal:** Build the left content pane of the review window.

**File:** `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift` (new file)

**Content pane (~65-70% width), top to bottom:**
1. **Artifact hero** — summary text from manifest (future: screenshot/recording)
2. **Milestone summary** — worker's description from brief.md
3. **Metadata line** — artifact count, milestone ID, revision number
4. **Artifacts list** — label + file path pairs from manifest.json
5. **Full brief text** — loaded from brief.md
6. **Previous round context** (revision 2+ only) — reads `decision.json` from milestone N-1, shows the user's last decision and note

**Manifest loading:** Move `DelegationReviewManifest` to a shared file (e.g., `Models/DelegationReviewManifest.swift`) so both the old `DelegationReviewView` and new `DelegationReviewWindow` use the same type. Do not duplicate — two copies will drift.

**Previous round lookup:** Parse current milestone ID as Int, subtract 1, format as `%02d`, read `decision.json` from that directory. For milestone "01", no previous round.

**Verification:**
```bash
./scripts/dev/restart-alpha-stable.sh
```

### Slice 2.3 — Decision rail

**Goal:** Build the right decision rail with card-based options.

**File:** `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewWindow.swift`

**Right rail (~30-35% width), static (non-scrolling):**

1. **Three option cards:**
   - **Approve** — "Ship this milestone and move on."
   - **Request Changes** — "Worker will address your feedback and submit a new revision."
   - **Write a Response** — "Provide custom instructions to the worker."

2. **Card interaction:** Clicking Request Changes or Write a Response expands a `TextEditor` within the rail for the note.

3. **"Write a Response" maps to `ReviewDecision.requestChanges`** — both produce the same enum, the distinction is UX only.

4. **"Submit Decision" button** at the bottom of the rail — calls `submitReviewDecision()` then dismisses the window.

5. **Revision 2+ adaptations:** Pre-fill with previous feedback, contextual labels ("Revision 2", "Round 3").

**Verification:**
```bash
./scripts/dev/restart-alpha-stable.sh
```

### Slice 2.4 — HUD card integration

**Goal:** The project card in the HUD shows a "Review Ready" badge. Tapping opens the review window instead of navigating to the inline view.

**Files (actual routing chain):**
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift` (~line 277) — vertical layout tap handler
- `apps/swift/Sources/Capacitor/Views/Projects/DockLayoutView.swift` (~line 160) — dock layout tap handler
- `apps/swift/Sources/Capacitor/Models/AppState.swift` — `handlePrimaryProjectAction()` (~line 1271) → `showDelegationReview()` (~line 1305)

**Changes:**
1. In `handlePrimaryProjectAction()`, when delegation status is `review_needed`, instead of calling `showDelegationReview()` (which pushes the inline view onto the navigation stack), call `setReviewWindowTarget()` and return a signal for the view to call `openWindow(id: "delegation-review")`.
2. Both `ProjectsView` and `DockLayoutView` tap handlers need to handle the new window-opening path using `@Environment(\.openWindow)`.
3. `DelegationReviewView.swift` remains for backward compatibility but is no longer the primary review surface.

**Verification:**
```bash
./scripts/dev/restart-alpha-stable.sh
```

### Slice 2.5 — Review window tests

**File:** `apps/swift/Tests/CapacitorTests/DelegationReviewWindowTests.swift` (new)

1. **Window opens with correct milestone data** (spec requirement) — verify the content pane displays the correct brief, manifest summary, and artifact list for the active milestone
2. **Previous round context** — verify it loads from milestone N-1, displays previous decision and note
3. **Decision rail actions** — verify approve/requestChanges dispatch correctly
4. **Window dismiss** — verify window closes after decision submission
5. **Malformed manifest graceful degradation** — verify the review window shows "no artifacts" when `manifest.json` is corrupt (moved here from Phase 1 since `DelegationReviewManifest` is extracted to shared code in Slice 2.2)

**Verification:**
```bash
swift test --package-path apps/swift
```

---

## Execution Order

The phases are independent — Phase 1 can ship without Phase 2.

```
Phase 1: [1.1 + 1.2 + 1.3 + 1.4] (single commit) → 1.5 (tests)
Phase 2: 2.1 → 2.2 → 2.3 → 2.4 → 2.5
```

**Phase 1 slices 1.1-1.4 are a single atomic commit.** The slice numbering is for development ordering within a branch, not for separate PRs. The WorkerPaths split, reconciliation rewrite, prompt rewrite, and helper updates must all land together — there is no valid intermediate state.

**Critical path:** Once Phase 1 lands, review iteration works with the existing inline view.

## Verification Commands

```bash
# After each slice
swift test --package-path apps/swift --filter DelegationLoopManagerTests
cargo test -p capacitor-core

# After Phase 1 complete
swift test --package-path apps/swift
cargo test -p capacitor-core
cargo fmt --check
cargo clippy -- -D warnings

# After Phase 2 complete
./scripts/dev/restart-alpha-stable.sh
swift test --package-path apps/swift
```

## Risk Notes

- **Phase 1 (1.1-1.4) is a single commit** — the WorkerPaths split creates compilation and behavioral dependencies across all four slices. The shim exists only as a mechanical aid during development.
- **Slice 1.1 is the riskiest** — it restructures `WorkerPaths` which has 7 callsites (see callsite inventory).
- **Milestone scanning relies on filesystem** — tests use real temp directories (matching existing test patterns).
- **Sentinel file is new convention** — worker prompts must be precise about write ordering.
- **Review window (Phase 2) is pure UI** — low risk, can iterate on design after shipping Phase 1.

## Known Edge Cases (Accepted)

- **Milestone 99+ overflow:** `%02d` produces 3-digit strings at 100. Accepted risk — 99 review rounds is implausible. If hit, behavior degrades gracefully (scanning still works with 3+ digit names since it parses as Int).
- **Resume failure recovery:** Uses staged `decision-pending.json` → rename to `decision.json` pattern. If Claude launch fails, the pending file is deleted and `decision.json` never appears. The milestone stays undecided, reconciler sees it, and the user can re-review. No immutability violation.
- **Worker crash mid-milestone:** Orphaned incomplete milestone directory. The reconciler correctly skips it (no sentinel). The delegation stays in `working` status until the user cancels. This is pre-existing behavior (a crashed worker currently causes the same stuck state) — timeout/cleanup is a separate feature.
- **Non-contiguous milestone numbering:** If milestone directories skip numbers (e.g., `01/`, `03/`), the previous-round lookup for milestone `03` would check `02/` and find nothing. Previous round context would display "no previous feedback." Accepted — non-contiguous numbering can't happen through normal flow.

## Review History

- **v1:** Initial plan written 2026-03-19
- **v2:** Addressed internal adversarial review (opus agent) — added callsite inventory, atomic slice constraint, missing tests (resume failure, prompt content, malformed manifest), Phase 2 state management fix (struct over tuple, live state over snapshot), AX identifier preservation, manifest type sharing decision
- **v3:** Addressed Codex adversarial review — staged decision write (`decision-pending.json` → `decision.json`) to preserve spec immutability contract; fixed Phase 2 window API surface (`@Environment(\.openWindow)` instead of calling from AppState, separate submission path for standalone window); corrected Slice 2.4 routing callsites (`ProjectsView`/`DockLayoutView` → `handlePrimaryProjectAction()` → `showDelegationReview()`); added missing "window opens with correct data" test; moved malformed manifest test to Slice 2.5 (depends on shared manifest type from 2.2); clarified request-changes exit semantics; strengthened slice atomicity to single commit

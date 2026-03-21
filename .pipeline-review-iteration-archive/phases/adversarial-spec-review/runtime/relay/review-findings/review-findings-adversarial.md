## Ship Review: Review Iteration Design Spec

### ISSUES

1. High: the spec's "decision preserved on disk" recovery path breaks its own milestone invariant and will not survive restart.
   Evidence:
   - The rules say the active review is "the highest-numbered milestone without `decision.json`" and that milestones with `decision.json` are immutable history (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:97-100`).
   - Reconciliation skips any highest milestone that already has `decision.json` (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:157-164`).
   - The test plan explicitly wants "Resume failure recovery: Claude launch fails -> delegation restores to review_ready with decision preserved on disk" (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:219-220`).
   - Current code already writes `decision.json` before launching Claude, then restores `review_ready` on launch failure without deleting that file (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:432-471`, `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:879-905`).
   Why this breaks:
   - After a failure, the in-memory reducer can say "review_ready" while the filesystem says "this milestone is decided history."
   - After app restart, or after any future reconcile that depends on disk, there is no undecided milestone to rediscover. The review is only "restored" until process memory is lost.
   - The same split-brain happens for any crash/failure after `decision.json` is written but before the next milestone becomes ready.

2. High: the design still trusts an untrusted worker to obey milestone sequencing, and there is no validator for wrong directories, skipped numbers, or completion-marker conflicts.
   Evidence:
   - The spec assumes flow-enforced sequencing and says the worker "can only create milestone N+1" after the user decides N (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:173-176`).
   - The proposed scanner only looks for the highest-numbered undecided directory; it does not compare against an expected next milestone (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:120-122`, `docs/superpowers/specs/2026-03-19-review-iteration-design.md:155-164`).
   - Completion still wins before milestone scanning (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:155-157`; current order is the same in `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:519-542`).
   - The reducer accepts any `milestone_id`, `brief_path`, and `manifest_path` pair; it does not enforce monotonic sequencing or path/milestone consistency (`core/capacitor-core/src/reduce/mod.rs:318-376`, `core/capacitor-core/src/domain/types.rs:190-195`, `core/capacitor-core/src/domain/types.rs:351-364`).
   Failure modes:
   - Worker writes `milestones/03/` when `02/` was expected: the scanner accepts `03`, and history now has a silent gap.
   - Worker writes new artifacts into decided `01/`: scanner ignores them forever because `decision.json` is present.
   - Worker writes both a new milestone and `completion.json`: reconcile completes immediately and the revised review is lost.
   - Worker creates both `02/` and `03/` undecided: the scanner picks `03`, leaving `02` orphaned with no review path.

3. High: the state machine has no "stuck" or "protocol violated" state, so incomplete milestones and non-terminating workers can leave delegations in permanent limbo.
   Evidence:
   - The spec says incomplete milestones should simply be skipped and assumes the worker will "eventually" finish (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:163-185`).
   - The domain model only exposes `working` and `review_needed`, with no degraded/error state for a crashed or off-protocol worker (`core/capacitor-core/src/domain/types.rs:168-180`).
   - Current reconciliation already has the same "skip and wait forever" shape when expected files are missing (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:544-570`).
   Why this matters:
   - If the worker creates `02/` and then dies before writing sentinel/files, the delegation stays `working` forever.
   - If the worker never exits after writing files, or never writes the expected next milestone, there is no timeout, stale-write detector, or user-facing recovery surface.
   - The user can lose the ability to get back to a reviewable state without going into the terminal and repairing the filesystem manually.

4. Medium: the standalone review-window design is under-specified and does not fit the current app state model.
   Evidence:
   - The spec proposes a singleton `Window(id: "delegation-review")` opened by `openWindow(id:)` (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:30-33`).
   - The app currently has only one main `WindowGroup`, and review routing lives inside main-window navigation state via `ProjectView.delegationReview(Project)` (`apps/swift/Sources/Capacitor/App.swift:18-87`, `apps/swift/Sources/Capacitor/Models/AppState.swift:10-26`, `apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift:39-43`, `apps/swift/Sources/Capacitor/Views/Navigation/NavigationContainer.swift:126-163`).
   - `showDelegationReview` and `submitDelegationReview` still mutate the main window route; submit unconditionally calls `showProjectList()` after a decision (`apps/swift/Sources/Capacitor/Models/AppState.swift:1305-1314`, `apps/swift/Sources/Capacitor/Models/AppState.swift:1555-1573`).
   Why this is a design gap:
   - A fixed `Window(id:)` does not explain how project identity is carried into the window.
   - The spec does not say what happens if the user opens review for project B while project A's review window is already open.
   - It also does not say whether a decision from the review window should still navigate the HUD back to the project list, which is what the current shared submit path does.

5. Medium: the spec is internally inconsistent about what "ready" means and what corrupt manifests should do.
   Evidence:
   - Request-changes prompt rewrite says requirements 7-8 do not apply and says "no exit after writing milestone," then immediately says "write `brief.md` and `manifest.json` ... then exit" (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:143-148`).
   - Reconciliation requires `.review-ready` and valid manifest parsing before `review_ready` fires (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:159-171`), but the request-changes rewrite in the prior section never explicitly includes the sentinel.
   - The test plan says corrupt/truncated manifests should gracefully degrade in the review view (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:213-214`), but the reconciliation rules say corrupt manifests should not reach review at all (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:160-164`).
   Consequence:
   - Different implementers can build materially different control flow and still believe they followed the spec.
   - QA will not know whether a corrupt manifest should block review or render a degraded review surface.

### CONCERNS

- The "concurrency-ready" claim is overstated. The reducer still rejects a second active delegation for the same `project_path` (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:231-232`, `docs/superpowers/specs/2026-03-19-review-iteration-design.md:258`, `core/capacitor-core/src/reduce/mod.rs:234-242`).

- Phase 1 explicitly reuses the existing inline review view (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:244-247`), but that view loads artifacts once per manifest path and does not reload if file contents change under the same path (`apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift:100-102`, `apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift:242-260`). If a worker touches a "ready" file too early and then corrects it, the UI can stay stale.

- The new Rust-test claim is directionally right, but the current contract suite still proves only the `01 -> resume -> complete` path. It does not yet pin `ReviewReady("02")` after `Resume`, nor any out-of-order milestone behavior (`core/capacitor-core/tests/delegation_contract.rs:26-162`).

- The current Swift tests also stop short of the spec's risk surface. They cover session attach behavior and an approve-path resume, but not request-changes iteration, numbered milestone scanning, bad milestone directories, dual milestone/completion output, or review-window lifecycle (`apps/swift/Tests/CapacitorTests/DelegationLoopManagerTests.swift:55-269`).

### POSITIVE

- The spec correctly identifies the current hard-coded `01` assumption and the current resume prompt's "finish and exit" behavior as the core blockers (`apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:241-243`, `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:852-870`, `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:953-988`).

- Adding a readiness sentinel plus manifest parsing is a real improvement over the current existence-only reconciliation logic, which would otherwise promote any visible `brief.md`/`manifest.json` pair (`docs/superpowers/specs/2026-03-19-review-iteration-design.md:159-171`, `apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift:544-570`).

- On the happy path, the reducer does appear milestone-id-agnostic enough to support `01 -> Resume -> 02 -> Resume -> Complete` without new mutation types, provided the new contract test is actually added (`core/capacitor-core/src/reduce/mod.rs:318-426`).

### VERDICT
ISSUES FOUND

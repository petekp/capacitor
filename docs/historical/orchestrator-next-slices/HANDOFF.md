# Resume: Orchestrator Runtime Core

> Doc role: `authoritative-plan`
> Status: Active

## Mission

Prepare and execute the migration from the validated delegation loop to the
larger project-level orchestrator architecture without regressing the proven
user loop or letting legacy `Workstreams` contaminate the new design.

## Resume Point

- Last meaningful action: kept merge-prep posture after the `slice-004` hardening pass and tightened proof instead of widening architecture. A fresh seam audit confirmed the remaining raw `RuntimeDelegationState` path is still `AppState` snapshot caching plus `DelegationLoopManager` side-effect reconciliation rather than a UI split-brain, new focused `DelegationLoopManagerTests` now prove the file-driven `working -> review_ready` and `working -> complete` transitions, `bash docs/plans/orchestrator-next-slices/guard.sh --status` still reproduces the pre-existing stall immediately after printing `== Baseline verifier groups ==`, and the outside-review bundle is packaged as `artifacts/review/orchestrator-runtime-core-2026-03-17/orchestrator-runtime-core-2026-03-17.zip`.
- Next command or file to open: `/Users/petepetrash/Code/capacitor/artifacts/review/orchestrator-runtime-core-2026-03-17/README.md`
- Success criterion for the next step: keep merge-prep posture. Either gather outside-review feedback from the packaged bundle, or name an exact obsolete dependency beyond the `DelegationLoopManager` side-effect seam that the next slice will delete before widening architecture again.

## Current State

- Done: the delegation-loop current state and history are consolidated in `STARTING_POINT.md`.
- Done: `Workstreams` is explicitly marked as legacy and slated for excision.
- Done: a full migration control-plane package exists under `docs/plans/orchestrator-next-slices/`.
- Done: `UBIQUITOUS_LANGUAGE.md` exists and names the canonical orchestrator vocabulary.
- Done: the revised orchestrator spec is now tracked at `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`.
- Done: the outside-review bundle now has a verified zip at `artifacts/review/orchestrator-runtime-core-2026-03-17/orchestrator-runtime-core-2026-03-17.zip`.
- In progress: the runtime orchestration core now has additive shell types for Orchestrator state and active Worker Runs, explicit `run_id` generation and Restart Recovery, a tiny Orchestrator mutation seam (`register`, `mark_stale`, `clear`), a typed append-only Journal in the snapshot, runtime-derived `project_orchestration_views`, authenticated runtime-service Orchestrator mutation transport, a reconnect-aware project-card caller in Swift, stale-marking that follows fresh exact-session evidence instead of raw retained-row presence, registration that works on both one-session and retained-history Project shapes, a runtime-representative handoff policy for replacing a registered Orchestrator session, a clear-and-recover path when the saved Orchestrator conversation is missing locally, and the current `slice-004` cuts that move Review payload, Review action context, and active delegated idea identity from raw delegation state into the runtime-owned orchestration projection consumed by cards, queues, Review chrome, and Review actions.
- Done during the latest hardening pass:
  - missing-conversation recovery now quarantines the disproved Orchestrator session from the local read model, excludes it from future Orchestrator Registration candidates, and waits for runtime `clear` success or disappearance before registering again
  - failed runtime `clear` mutations during stale-resume recovery now surface UI feedback and retry while the blocked Orchestrator still exists in runtime state
  - `project_orchestration_views` now prefer active Delegation Loop truth over stale Orchestrator metadata, so `active_idea_id` remains visible when a stale Orchestrator and a still-working Worker coexist
- Done during the latest merge-prep check:
  - the remaining Swift `RuntimeDelegationState` usage is still `AppState` runtime snapshot caching plus `DelegationLoopManager.reconcile(delegations:)`, not a project-card / queue / review UI dependency
  - forcing that seam into `project_orchestration_views` right now would widen a consumer-shaped projection with worker-reconcile details needed only by one local side-effect boundary
  - focused `DelegationLoopManagerTests` now prove the remaining file-driven Swift reconcile seam emits `review_ready` from review artifacts and `complete` from the completion marker
- Not done: project-level orchestration behavior beyond the current runtime shell/read models.

## Repo State

- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `pkp/delegation-loop-stabilization`
- Working tree: dirty by design from orchestrator planning artifacts, runtime-core Rust changes, regenerated UniFFI bridge/header, and some unrelated verifier `__pycache__` noise
- Relevant branch context:
  - `2ce3435` — current delegation-loop stabilization head
  - `840b4cc` — native delegation review loop PR rollup
  - `d11aabd` on `main` — original source commit for the March 15 / March 16 orchestrator design docs; the revised March 16 spec is now tracked on this branch

## Key Artifacts

- `/Users/petepetrash/Code/capacitor/docs/plans/orchestrator-next-slices/AGENT_EXECUTION_PLAYBOOK.md`
  - single-file entrypoint for future coding agents
- `/Users/petepetrash/Code/capacitor/UBIQUITOUS_LANGUAGE.md`
  - canonical glossary for the orchestrator domain
- `/Users/petepetrash/Code/capacitor/docs/plans/orchestrator-next-slices/SLICES.yaml`
  - slice sequencing, deletion targets, and verification commands
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/tests/delegation_contract.rs`
  - now includes the first runtime-shell contract for explicit active worker run identity, restart recovery, and typed orchestration journal history
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/tests/ffi_contract.rs`
  - now includes runtime-shell tests for orchestrator registration, stale marking, clearing, and restart recovery
- `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs`
  - now mints and clears `ActiveWorkerRunState` from existing delegation mutations, owns the minimal Orchestrator mutation seam, appends typed orchestration Journal events from those same authoritative transitions, derives runtime-owned Project orchestration modes, includes both pending Review payload and Review action context when a Review is needed, exposes `active_idea_id` when the Delegation Loop is actively working, and keeps that active projection visible even when the explicit Orchestrator record is stale
- `/Users/petepetrash/Code/capacitor/core/hud-hook/src/serve.rs`
  - now exposes the minimal authenticated `POST /runtime/orchestrator/mutate` transport that forwards explicit orchestrator mutations into the shared runtime
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift`
  - now caches runtime-derived Project orchestration views and explicit Orchestrator state keyed by normalized Project path, prefers reconnect over duplicate launch when the runtime says an Orchestrator exists, clears unusable saved Orchestrator conversations before falling back to a fresh Project open, registers pending Orchestrators by following the runtime Project summary's representative exact root-project session, hands off registered Orchestrators to a new runtime-representative session after two fresh matching snapshots, marks stale only when fresh exact-session evidence disappears even if retained history rows remain, and now quarantines dead Orchestrator sessions until runtime `clear` succeeds or disappears while retrying failed clears with surfaced UI feedback
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/RuntimeClient.swift`
  - now decodes orchestrators, active worker runs, orchestration events, project orchestration views (including `current_review`, `review_context`, and `active_idea_id`), and runtime snapshot `generated_at` from the runtime snapshot, and exposes the matching runtime-service orchestrator mutation request
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift`
  - now resumes review decisions from runtime-owned review action context instead of a raw `RuntimeDelegationState` convenience overload
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Utilities/ProjectPrimaryActionResolver.swift`
  - now treats the runtime-owned orchestration view as the review-ready routing signal instead of requiring raw delegation Review payload presence as a second gate, and keeps reconnect behavior aligned with `mode = active` even when the Orchestrator record itself is stale
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Utilities/IdeaQueueStatusResolver.swift`
  - now maps both review-ready and delegation-working queue state from the runtime-owned orchestration view payload (`reviewContext.ideaId`, `activeIdeaId`) instead of raw delegation state, which keeps queue state stable once the runtime projection prefers active delegation over stale Orchestrator metadata
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Views/Projects/ProjectDetailView.swift`
  - now renders idea-queue activity without fetching `AppState.delegationState(for:)`, so project detail stays on the runtime-owned orchestration projection like the rest of the nearby review UI
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Views/Projects/DelegationReviewView.swift`
  - now reads and submits through the runtime-owned review projection so the review detail screen stays aligned with `review_needed` project routing without waiting on raw delegation payload
- `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
  - now owns the local `claude --resume <session_id>` reconnect side effect used by project-card primary action and checks saved Claude project-session metadata before attempting a reconnect that would dead-end
- `/Users/petepetrash/Code/capacitor/artifacts/manual-testing/orchestrator-runtime-smoke-2026-03-17.md`
  - live and fixture-backed smoke notes for registration, reconnect, stale-marking, handoff, native review-surface proof, and the remaining queue-badge visibility limitation
- `/Users/petepetrash/Code/capacitor/artifacts/review/orchestrator-runtime-core-2026-03-17/README.md`
  - persistent external-review bundle entrypoint describing the merge-prep `slice-004` convergence cut, known concerns, and included files; sibling `PROMPT.md` and `filelist.txt` are there to regenerate the zip or hand it off quickly
- `/Users/petepetrash/Code/capacitor/artifacts/review/orchestrator-runtime-core-2026-03-17/orchestrator-runtime-core-2026-03-17.zip`
  - generated outside-review archive containing the review README, prompt, file list, and all referenced source / test / planning files; `unzip -l` now serves as the quick integrity check
- `/Users/petepetrash/.capacitor/runtime/app-debug.log`
  - decisive live evidence:
    - earlier `AppState.orchestratorRegistration skipped ... reason=ambiguous_exact_sessions count=17` for `capacitor`
    - later `AppState.orchestratorRegistration start ... session=5fadadd4-af1f-40fb-a532-a60bd17588fd` and `success` for `capacitor`
    - after deploying handoff logic, `AppState.orchestratorReplacement start ... from_session=f88a6ebf-11f6-45d9-81b5-6647384eb58a to_session=5fadadd4-af1f-40fb-a532-a60bd17588fd` and `success` for `capacitor`
    - after deploying fresh-evidence stale marking, `AppState.orchestratorLiveness mark_stale_start ...` and `mark_stale_success ...` now appear for both `capacitor` and `personality`
    - `AppState.orchestratorRegistration success ... session=321ebeb7-d66d-406d-aa90-41e0ab340c72` for `personality`
    - `[TerminalLauncher] resumeClaudeSession launched projectPath=/Users/petepetrash/Code/personality sessionID=321ebeb7-d66d-406d-aa90-41e0ab340c72`
    - after the stale-card recovery fix, missing saved conversations now emit `[TerminalLauncher] resumeClaudeSession unavailable ... detail=No conversation found with session ID: ...` followed by `AppState.orchestratorReconnect fallback_clear_start ...` / `success`
- `/Users/petepetrash/.capacitor/runtime/app_snapshot.json`
  - live runtime snapshot currently shows `personality` as `status = stale` / `mode = stale_orchestrator`, and `capacitor` has already round-tripped through a temporary fresh replacement session back to `status = stale` / `mode = stale_orchestrator`
- `/Users/petepetrash/Code/capacitor/docs/plans/orchestrator-next-slices/RATCHETS.yaml`
  - initial anti-regression budgets, especially for legacy Workstreams references
- `/Users/petepetrash/Code/capacitor/docs/plans/orchestrator-next-slices/STARTING_POINT.md`
  - historical synthesis and branch archaeology
- `/Users/petepetrash/Code/capacitor/.capacitor/worktrees/delegation-09f5dc64/docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md`
  - related worktree copy of the same revised spec; useful only as a secondary reference now that the spec is tracked on the active branch

## Project Rules

- Use the terms in `UBIQUITOUS_LANGUAGE.md`.
- Do not build new orchestrator work on `WorkstreamsManager` or `WorkstreamsPanel`.
- Start behavior changes with failing tests when a good seam exists.
- Carry deletions in the same slice that replaces the old path.
- Update `DECISIONS.md`, `SLICES.yaml`, `MAP.csv`, and `HANDOFF.md` as part of the work.

## Established Decisions

- Runtime service is the machine-readable orchestration authority.
- Delegation loop value should be preserved but not treated as the final architecture.
- Workstreams is legacy and slated for excision.
- Ubiquitous language is mandatory for this migration.
- Foundation hardening precedes the broad implementation slices.
- The tracked revised March 16 spec is now the current architecture target on this branch.
- The first step inside `slice-002` is to preserve the current delegation-loop value while making run identity and minimal orchestrator identity explicit before widening orchestrator behavior.
- The current `slice-002` increment now also proves a typed orchestration journal without introducing a separate journal store or registration transport.
- The current `slice-002` increment also proves runtime-derived project orchestration modes for cards and nearby Swift read models without adding reconnect behavior yet.
- The explicit registration transport now exists end-to-end; the remaining choice is registration policy, not more plumbing.
- Project-card primary action is now the first reconnect-aware caller.
- Project-card open flow is now the first trustworthy registration caller.
- Multi-session project registration now follows the runtime representative exact root-project session instead of requiring exact-path cardinality of one.
- Registered orchestrators now hand off to a different runtime-representative exact root-project session after two consecutive fresh snapshots, without waiting for old retained rows to disappear.
- Registered exact root-project sessions now have to be fresh, not merely present, before they keep the project `active`.
- The remaining raw `RuntimeDelegationState` seam is intentionally limited to runtime snapshot caching plus `DelegationLoopManager` side-effect reconciliation until a future slice names a dedicated replacement boundary.
- The remaining file-driven `DelegationLoopManager.reconcile(...)` transitions now have focused Swift proofs and should stay that way until the seam is deleted or replaced.
- Live smoke proved both that the old exact-count predicate was too strict for real retained session history and that the runtime-representative registration rule fixes `capacitor` without reviving local heuristics.

## Assumptions

- The next major step should be external review or branch cleanup rather than more local `slice-004` widening, unless a future cut can name the exact obsolete dependency it will delete.
- The revised March 16 spec remains the best long-term architecture target.
- The existing delegation-loop tests should be evolved forward, not duplicated into a second system.
- The project detail idea queue should consume the same runtime-owned orchestration projection as review routing and review actions; if a UI consumer needs only one lifecycle fact, prefer adding that minimal fact to the projection over leaking a broader source record.
- No equally clear `slice-004` convergence cut is currently proven after landing `active_idea_id`; the branch is in a healthier merge-prep state now, so any additional architecture movement should clear a higher bar than “it seems like the next thing nearby.”
- The new review package should be treated as the default next-step artifact for outside feedback; more local widening should wait for either a named deletion target or reviewer findings.
- The three confirmed review findings have been hardened: dead `AppState.delegationStates` deleted, stale VoiceOver copy fixed, and clippy issues resolved. The current projection cut is merge-ready.

## Verification State

- Passed before this control-plane package was created:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `swift test --package-path apps/swift --filter DelegationLoopManagerTests`
  - `swift test --package-path apps/swift --filter IdeaQueueStatusResolverTests`
  - `swift test --package-path apps/swift --filter ProjectPrimaryActionResolverTests`
- Passed during `slice-002` start:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `cargo test -p capacitor-core --test ffi_contract`
  - `cargo test -p capacitor-core`
  - `cargo build -p capacitor-core --release`
  - `swift build --package-path apps/swift`
  - `swift test --package-path apps/swift --filter RuntimeClientTests`
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|RuntimeClientTests|AppStateSessionObservationTests'`
- Passed after adding orchestration event vocabulary:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `cargo test -p capacitor-core --test ffi_contract`
  - `cargo test -p capacitor-core`
  - `cargo build -p capacitor-core --release`
  - `swift test --package-path apps/swift --filter RuntimeClientTests`
- Passed after adding runtime-derived project orchestration views:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `cargo test -p capacitor-core`
  - `cargo build -p capacitor-core --release`
  - `swift test --package-path apps/swift --filter RuntimeClientTests`
  - `swift test --package-path apps/swift --filter ProjectPrimaryActionResolverTests`
  - `swift test --package-path apps/swift --filter IdeaQueueStatusResolverTests`
  - `swift test --package-path apps/swift --filter 'IdeaQueueStatusResolverTests|DelegationLoopManagerTests|RuntimeClientTests|AppStateSessionObservationTests|ProjectPrimaryActionResolverTests'`
- Passed after landing explicit orchestrator mutation transport:
  - `cargo test -p hud-hook runtime_orchestrator_mutation_endpoint_updates_shared_runtime_snapshot`
  - `cargo test -p hud-hook`
  - `swift test --package-path apps/swift --filter RuntimeClientTests`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests'`
- Passed after landing the first reconnect-aware caller:
  - `swift test --package-path apps/swift --filter ProjectPrimaryActionResolverTests`
  - `swift test --package-path apps/swift --filter AppStateTerminalActivationTests`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests|TerminalLauncherTests|IdeaQueueStatusResolverTests|DelegationLoopManagerTests'`
- Passed after landing the first trustworthy registration caller:
  - `swift test --package-path apps/swift --filter AppStateTerminalActivationTests`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests'`
  - `cargo test -p capacitor-core`
- Passed after landing the first trustworthy stale-marking caller:
  - `swift test --package-path apps/swift --filter AppStateTerminalActivationTests`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests'`
  - `cargo test -p capacitor-core`
- Passed in live smoke after fixing the stale runtime server:
  - AX click on `ax.project-card.personality` registered an active orchestrator for session `321ebeb7-d66d-406d-aa90-41e0ab340c72`
  - after app restart, AX click on `ax.project-card.personality` logged `resumeClaudeSession launched ... sessionID=321ebeb7-d66d-406d-aa90-41e0ab340c72`
- Passed after replacing the registration predicate with runtime-representative selection:
  - `swift test --package-path apps/swift --filter 'AppStateTerminalActivationTests/testPrimaryProjectActionRegistersRuntimeRepresentativeSessionWhenProjectHistoryHasMultipleExactSessions|AppStateTerminalActivationTests/testPrimaryProjectActionRegistersExactProjectSessionAfterOpeningTerminal|AppStateTerminalActivationTests/testPrimaryProjectActionDoesNotRegisterWorktreeSessionAsOrchestrator|AppStateTerminalActivationTests/testPendingProjectRegistrationDoesNotRepeatForSameExactSession'`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests'`
  - `cargo test -p capacitor-core`
  - live AX click on `ax.project-card.capacitor` logged `AppState.orchestratorRegistration start ... session=5fadadd4-af1f-40fb-a532-a60bd17588fd` followed by `success`
  - live runtime snapshot now shows an active orchestrator record for `/users/petepetrash/code/capacitor` with `session_id = 5fadadd4-af1f-40fb-a532-a60bd17588fd`
- Passed after landing runtime-representative handoff with hysteresis:
  - `swift test --package-path apps/swift --filter 'AppStateTerminalActivationTests/testActiveOrchestratorReplacesWithNewRuntimeRepresentativeSessionAfterHysteresis|AppStateTerminalActivationTests/testOrchestratorReplacementDoesNotRepeatForSameRuntimeRepresentativeSession'`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests'`
  - `cargo test -p capacitor-core`
  - rebuilding and restarting the debug app produced a live handoff for `capacitor`: `AppState.orchestratorReplacement start ... from_session=f88a6ebf-11f6-45d9-81b5-6647384eb58a to_session=5fadadd4-af1f-40fb-a532-a60bd17588fd` followed by `success`
  - current runtime snapshot now shows `/users/petepetrash/code/capacitor` registered to `session_id = 5fadadd4-af1f-40fb-a532-a60bd17588fd`
  - a separate `claude -p 'Reply with OK and nothing else.'` probe at `/Users/petepetrash/Code/capacitor` did not create a new runtime-tracked exact root-project session row, so that narrower live creation path is still unproven
- Passed after refining stale-marking to use fresh exact-session evidence anchored to runtime snapshot time:
  - `swift test --package-path apps/swift --filter 'AppStateTerminalActivationTests/testActiveOrchestratorMarksStaleWhenRetainedExactSessionRowIsOnlyHistoricalEvidence|AppStateTerminalActivationTests/testActiveOrchestratorMarksStaleAfterTwoFreshSnapshotsWithoutExactProjectSession|AppStateTerminalActivationTests/testExactProjectSessionResetsStaleMarkingHysteresis|AppStateTerminalActivationTests/testStaleMarkingDoesNotRepeatForSameRegisteredOrchestrator'`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests'`
  - direct snapshot check on `/Users/petepetrash/.capacitor/runtime/app_snapshot.json` showed the current registered orchestrator sessions for `capacitor` and `personality` are `3357s` and `3165s` old relative to runtime `generated_at`, so the new five-minute rule correctly classifies those retained ready rows as stale evidence rather than live proof
- Passed in live smoke after restarting the debug app with the refined stale-marking rule:
  - killed the existing runtime server, ran `scripts/dev/restart-app.sh --swift-only`, and let two fresh runtime snapshots apply
  - app log emitted `AppState.orchestratorLiveness mark_stale_start ... misses=2` followed by `mark_stale_success` for both `/users/petepetrash/code/capacitor` and `/users/petepetrash/code/personality`
  - live runtime snapshot now shows both projects with orchestrator `status = stale` and project orchestration `mode = stale_orchestrator`
- Passed in live smoke after creating a brand-new tracked root-project Claude session while the app was already running:
  - launched an interactive `claude` session at `/Users/petepetrash/Code/capacitor`, which produced new exact session `7aeac579-0914-4c50-88f4-bc2d56476952` in the runtime snapshot
  - app log emitted `AppState.orchestratorReplacement start ... from_session=5fadadd4-af1f-40fb-a532-a60bd17588fd to_session=7aeac579-0914-4c50-88f4-bc2d56476952 observations=2` followed by `success`
  - after that temporary interactive session exited, app log emitted the reverse replacement back to `5fadadd4-af1f-40fb-a532-a60bd17588fd` followed by a fresh stale-mark for that retained session, which shows the running app follows runtime representative changes in both directions
- Passed during `slice-004` first cut:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests'`
- Passed after extending `slice-004` through review action submission and deleting the temporary compatibility path:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests'`
- Passed after adding `active_idea_id` to the runtime-owned orchestration projection and deleting the project-detail raw delegation accessor:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests'`
- Passed during fixture-backed merge-prep smoke for the latest `slice-004` projection cut:
  - standalone runtime fixture built from source `delegations` / `active_worker_runs` derived `mode = active` with the expected `active_idea_id` for `capacitor`
  - AX click on `ax.project-details.capacitor` followed by presence of `ax.nav.back-projects` proved project-detail navigation under that active fixture
  - standalone runtime fixture built from source `review_needed` delegation state derived the expected `current_review` and `review_context`
  - AX click on `ax.project-card.capacitor` used named action `Open Review`, and `ax.delegation-review` plus `ax.delegation-review.approve` were both present in the real app
- Passed during merge-prep widening after the `slice-004` cleanup:
  - `cargo test -p capacitor-core`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests|TerminalLauncherTests|DelegationLoopManagerTests|IdeaQueueStatusResolverTests'`
  - `swift build --package-path apps/swift`
- Passed again during external-review packaging for the current merge-prep state:
  - `cargo test -p capacitor-core`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests|TerminalLauncherTests|DelegationLoopManagerTests|IdeaQueueStatusResolverTests'`
  - `swift build --package-path apps/swift`
- Passed during adversarial review after tracing the runtime and Swift projection seams:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests|AppStateTerminalActivationTests'`
- Passed after hardening the three confirmed review findings:
  - `cargo test -p capacitor-core --test delegation_contract`
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests|AppStateTerminalActivationTests'`
- Passed during outside-review packaging cleanup:
  - `unzip -l artifacts/review/orchestrator-runtime-core-2026-03-17/orchestrator-runtime-core-2026-03-17.zip`
- Passed after post-review cleanup (deleted dead `AppState.delegationStates`, fixed stale VoiceOver copy, fixed 3 clippy errors in `reduce/mod.rs`):
  - `cargo fmt --check` (clean)
  - `cargo clippy -p capacitor-core -- -D warnings` (clean)
  - `cargo test -p capacitor-core` (233 passed, 0 failed)
  - `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|AppStateTerminalActivationTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests|AppStateSessionObservationTests|TerminalLauncherTests'` (93 passed, 0 failures)
  - `rg "delegationStates"` repo-wide (zero matches)
- Passed after tightening the remaining Swift side-effect seam:
  - `swift test --package-path apps/swift --filter DelegationLoopManagerTests`
  - `swift test --package-path apps/swift --filter 'RuntimeClientTests|AppStateSessionObservationTests|AppStateTerminalActivationTests|ProjectPrimaryActionResolverTests|IdeaQueueStatusResolverTests|TerminalLauncherTests'`
  - `cargo test -p capacitor-core --test delegation_contract`
- Not run during the adversarial review:
  - `bash docs/plans/orchestrator-next-slices/guard.sh --status` because the existing handoff already records a pre-existing stall in the verifier pipeline at `scripts/verify/extract-facts.py --report-only`
  - `scripts/gather-git-state.sh` because the repo does not currently have that script
- Practical note:
  - after regenerating the UniFFI bridge/header, SwiftPM picked up a stale staged `libcapacitor_core.dylib` in `apps/swift/.build/arm64-apple-macosx/debug/` before the fresh release dylib. Copying the new release dylib into that debug directory fixed the undefined-symbol linker failure for `mutateOrchestrator`.
  - the first live smoke failures against `personality` were environmental, not product-level: port `7474` was held by a stale long-running `~/.local/bin/hud-hook serve` process. Killing it and relaunching the app restored the current runtime route and moved `POST /runtime/orchestrator/mutate` from `404`/auth drift to a working `200`.
- re-running `bash docs/plans/orchestrator-next-slices/guard.sh --status` still appears to stall during the baseline verifier handoff to `scripts/verify/extract-facts.py --report-only`; a local 20-second alarm reproduced the same hang, so treat it as a pre-existing verifier issue unless proven otherwise.
- a fresh 20-second rerun of `bash docs/plans/orchestrator-next-slices/guard.sh --status` again printed all control-plane artifacts, then stopped immediately after `== Baseline verifier groups ==` without listing any group names, which matches the pre-existing verifier stall rather than exposing a new orchestrator regression.
  - for synthetic runtime smoke, editing `project_orchestration_views` directly in a snapshot file is ineffective because the runtime recomputes that projection from source records on boot. Fixtures must be built from `delegations`, `active_worker_runs`, and `orchestrators`.
  - the current lightweight HUD/AX harness can prove project-detail navigation and native review-surface presence, but it is still awkward for asserting queue badge text directly because the floating HUD shares the desktop with other foreground apps and the combined queue-row accessibility value was not cleanly discoverable.

## Rejected Paths

- Do not treat the current one-active-delegation state model as the long-term orchestrator architecture.
- Do not revive file-authoritative orchestration.
- Do not let `Workstreams` become the migration substrate.
- Do not keep the current “exactly one exact-path session” gate as the long-term registration rule; live repos already violate it.

## Open Questions / Risks

- How much of the revised spec should be landed verbatim versus adapted to current branch reality?
- Does orchestrator registration need a minimal MCP adapter immediately, or can it start with a thinner bridge?
- How much of session genealogy is necessary for the first runtime orchestration shell versus later?
- Manual smoke is no longer fully pending: fixture-backed app proof covers the native review path and project-detail navigation for the latest `slice-004` projection cut, but the queue badge text itself is still only indirectly covered by focused tests plus runtime-fixture derivation.
- `bash docs/plans/orchestrator-next-slices/guard.sh --status` still appears to stall in the pre-existing verifier pipeline handoff to `scripts/verify/extract-facts.py --report-only`, so branch cleanup still needs to treat that as environmental debt unless proven otherwise.

## Notes For The Next Agent

- Start from merge-prep posture, not fresh widening.
- Do not spend another session rediscovering the three confirmed hardening bugs; they are fixed and covered.
- `slice-003` now has automated and live proof for registration, reconnect, stale-marking, and handoff; `slice-004` is still marked in progress, but the runtime-owned projection now covers review routing, review reads/actions, and active-idea queue status too.
- Read the playbook first, not the older exploratory docs.
- Read `/Users/petepetrash/Code/capacitor/artifacts/review/orchestrator-runtime-core-2026-03-17/README.md` first if you are preparing an outside review or need the shortest high-signal explanation of the current merge-prep state.
- The remaining Swift `RuntimeDelegationState` usages are now the underlying runtime snapshot / `DelegationLoopManager` seam, not project-detail or project-card UI consumers.
- Do not treat `DelegationLoopManager.reconcile(delegations:)` as the next automatic deletion target; if you want to remove that seam later, first name the replacement runtime-owned worker-reconcile boundary.
- The new focused `DelegationLoopManagerTests` cover the file-marker reconcile paths. Keep extending those tests if the seam changes before any later slice replaces it.
- Read `/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/AppState.swift:1359` if you need to understand the unavailable-Orchestrator recovery state machine or why the dead session stays quarantined until runtime catches up.
- Read `/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs:836` if you need to understand why active Delegation Loop truth now outranks stale Orchestrator metadata in the runtime-owned projection.
- Read `/Users/petepetrash/Code/capacitor/artifacts/manual-testing/orchestrator-runtime-smoke-2026-03-17.md`; it now includes a fixture-backed `slice-004` smoke that proved the native review surface in the real app and documented the remaining queue-badge visibility limitation.
- The failing-first coverage for the latest hardening pass now lives in:
  - `/Users/petepetrash/Code/capacitor/apps/swift/Tests/CapacitorTests/AppStateTerminalActivationTests.swift`
  - `/Users/petepetrash/Code/capacitor/core/capacitor-core/tests/delegation_contract.rs`
  - `/Users/petepetrash/Code/capacitor/apps/swift/Tests/CapacitorTests/ProjectPrimaryActionResolverTests.swift`
- If you keep pushing `slice-004` beyond these hardening fixes, name the exact obsolete dependency you are deleting before writing code. If you cannot name it precisely, stop after the hardening pass and reassess.
- Regenerate the external review zip from `artifacts/review/orchestrator-runtime-core-2026-03-17/README.md` and `filelist.txt` if you need to hand the current branch to another reviewer; the persistent `PROMPT.md` is already tailored for that package.
- Read `/Users/petepetrash/Code/capacitor/artifacts/manual-testing/orchestrator-runtime-smoke-2026-03-17.md`; it now captures both the original retained-history failure mode and the runtime-representative registration fix.
- Read `/Users/petepetrash/.capacitor/runtime/app_snapshot.json`; the current steady-state snapshot should show both `capacitor` and `personality` as `stale`, but the app-debug log now contains the transient live handoff to `7aeac579-0914-4c50-88f4-bc2d56476952` and the later fallback back to `5fadadd4-af1f-40fb-a532-a60bd17588fd`.
- If you discover a mismatch between the revised spec and the current validated delegation loop, write a `DECISIONS.md` entry before changing code.

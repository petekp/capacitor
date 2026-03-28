# Architecture Decisions

> Doc role: `authoritative-plan`
> Status: Active

Append-only. Never edit or delete past entries. If a decision changes, add a
new entry that supersedes the old one.

---

## Decision 1: The runtime service is the orchestration authority
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** The delegation loop proved the user value of async delegation, but the revised orchestrator design showed that file-authoritative orchestration would create split-brain lifecycle ownership.
- **Decision:** The filesystem remains the durable artifact store, while the authenticated local runtime service remains the authoritative machine-readable orchestration boundary.
- **Alternatives considered:** File-authoritative orchestration was rejected because lifecycle transitions, identity, and restart recovery need typed ownership and ordering.
- **Consequences:** Future orchestrator work must center on runtime-owned commands, events, and read models. Swift must not become a second orchestration authority.
- **Supersedes:** none

## Decision 2: Preserve the validated delegation loop, but do not treat it as the final architecture
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** The current branch contains a real delegation loop that should not be discarded, but its one-active-delegation-per-project model is intentionally narrow.
- **Decision:** Future slices should preserve the proven user loop while re-homing it under the larger orchestrator control plane.
- **Alternatives considered:** Freezing the delegation loop as the long-term architecture was rejected because it would stretch a slice-specific state model into an accidental platform.
- **Consequences:** The runtime orchestration core must absorb the loop without forking the user experience.
- **Supersedes:** none

## Decision 3: `Workstreams` is legacy and slated for excision
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** `Workstreams` and the new orchestrator both touch worktrees, which makes accidental conceptual drift likely.
- **Decision:** The orchestrator may reuse `WorktreeService` as low-level substrate, but must not depend on `WorkstreamsManager`, `WorkstreamsPanel`, or `workstreams` feature semantics.
- **Alternatives considered:** Keeping `Workstreams` as a parallel supported abstraction was rejected because it muddies the domain language and encourages architectural contamination.
- **Consequences:** Ratchets should freeze or reduce legacy `Workstreams` references, and future orchestrator docs should describe it only as legacy.
- **Supersedes:** none

## Decision 4: Ubiquitous language is mandatory for this migration
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** The domain currently has multiple overlapping concepts: worktree, worker, workstream, session, run, delegation, orchestration, review, and decision.
- **Decision:** `UBIQUITOUS_LANGUAGE.md` is canonical for this feature. Future slices must use those terms in tests, docs, and code review discussion.
- **Alternatives considered:** Relying on informal consistency was rejected because this work crosses runtime, Swift, docs, and multiple sessions/agents.
- **Consequences:** Ambiguous or overloaded terms should be renamed or explicitly flagged during implementation.
- **Supersedes:** none

## Decision 5: Foundation hardening comes before broad implementation
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** The current context is rich but scattered across the branch, worktrees, and planning docs.
- **Decision:** Before the major implementation slices begin, the revised architecture, ubiquitous language, migration control plane, and legacy quarantine must be made explicit on the current branch.
- **Alternatives considered:** Jumping straight into orchestrator code was rejected because it would reintroduce ambiguity about target architecture and ownership.
- **Consequences:** `slice-001` is a foundation-hardening slice, not product-surface expansion.
- **Supersedes:** none

## Decision 6: The tracked revised March 16 spec is the current architecture target
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** The larger orchestrator vision was previously scattered across `main`, related worktrees, and planning notes, while the current branch lacked a tracked authoritative architecture spec.
- **Decision:** `docs/superpowers/specs/2026-03-16-orchestrator-design-revised.md` is now the tracked architecture target for orchestrator work on this branch. The March 15 draft is superseded historical context, not an active target.
- **Alternatives considered:** Continuing to rely on the worktree-only copy or the superseded March 15 draft was rejected because future agents need one tracked source of truth on the active branch.
- **Consequences:** Future slices should align the playbook, charter, and code changes to the revised spec. Any contradiction between that spec and implementation reality should be resolved with a new decision entry, not ad hoc drift.
- **Supersedes:** none

## Decision 7: Start the runtime orchestration core by making run identity explicit inside the existing delegation loop
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** `slice-002` needs to begin the runtime orchestration shell without prematurely widening into orchestrator registration or a broad new control surface. The current validated delegation loop already has stable worker identity and session-resume semantics, but it lacked explicit run identity.
- **Decision:** The first `slice-002` increment adds additive runtime shell types for future orchestrator state plus explicit active worker run tracking driven by existing delegation mutations. This makes `run_id` a first-class concept and proves restart recovery for in-flight runs before orchestrator registration is introduced.
- **Alternatives considered:** Jumping directly to orchestrator registration was rejected because it belongs to `slice-003` and would broaden the control surface before the runtime shell was proven. Leaving run identity implicit was rejected because process episodes and conversation identity are distinct concepts that the larger architecture depends on.
- **Consequences:** Future work should treat worker, worker session, and run as separate concepts. The next `slice-002` increment should remain narrow and focus on explicit orchestration vocabulary or a minimal orchestrator-state seam rather than full registration behavior.
- **Supersedes:** none

## Decision 8: Add a tiny orchestrator mutation seam before full registration/reconnect
- **Date:** 2026-03-16
- **Status:** Active
- **Context:** Once the runtime shell had explicit active worker run identity, the next narrow step was deciding whether `ProjectOrchestratorState` should remain a passive snapshot shape until `slice-003`, or become a minimal mutable runtime concept immediately.
- **Decision:** `slice-002` adds a tiny orchestrator mutation seam with `register`, `mark_stale`, and `clear`, but stops there. It does not add reconnect policy, transport breadth, or UI flow ownership yet.
- **Alternatives considered:** Leaving orchestrator state entirely inert until `slice-003` was rejected because the runtime shell benefits from proving that orchestrator identity can persist and recover. Jumping directly to full registration/reconnect behavior was rejected because that would collapse `slice-002` into `slice-003`.
- **Consequences:** The runtime now owns a minimal orchestrator lifecycle shell, and the next increment can build explicit event vocabulary or read-model convergence without re-opening the question of whether orchestrator identity belongs in runtime state.
- **Supersedes:** none

## Decision 9: Land the first orchestration journal as typed snapshot history before separate journal storage
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After explicit orchestrator identity and worker run identity were in place, the runtime still exposed only latest state. That made restart recovery debuggable only by inference and left no typed history seam for future projections.
- **Decision:** `slice-002` adds a typed append-only orchestration event vocabulary inside the persisted runtime snapshot. Existing delegation and orchestrator mutations now emit additive journal events such as orchestrator registration, worker run start, review request, review decision recording, and stale marking. This remains a read-model/history seam, not a separate transport or standalone journal storage subsystem yet.
- **Alternatives considered:** Waiting for a dedicated journal store was rejected because it would overbroaden the slice. Continuing with latest-state-only snapshots was rejected because recovery and future project-level read models would keep reverse-engineering transitions from incidental state fields.
- **Consequences:** The runtime snapshot and Swift read model now expose explicit orchestration history. Future projections should prefer the typed event vocabulary over ad hoc timestamp inference, and any later dedicated journal storage should preserve this vocabulary rather than invent a second one.
- **Supersedes:** none

## Decision 10: Derive project orchestration modes in runtime before registration/reconnect transport
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After the journal landed, project cards and idea-queue surfaces in Swift still inferred review-needed state directly from raw delegation fields. That preserved behavior, but it kept lifecycle interpretation in the UI instead of the runtime read model.
- **Decision:** `slice-002` adds an additive runtime-derived `project_orchestration_views` read model with explicit modes such as `active`, `review_needed`, and `stale_orchestrator`, derived from the existing orchestrator/delegation/run shell. Swift now consumes that view for project-card routing/chrome and idea-queue review readiness while still using delegation payloads for review details.
- **Alternatives considered:** Continuing to infer card modes in Swift from raw delegation/orchestrator fields was rejected because it would keep the UI as a second lifecycle interpreter. Jumping straight to reconnect behavior was rejected because that belongs to `slice-003`.
- **Consequences:** Project-card and idea-queue lifecycle semantics now converge on runtime-owned read models without widening the transport surface. The next major step should shift toward explicit registration/reconnect transport rather than adding more ad hoc UI inference.
- **Supersedes:** none

## Decision 11: Land explicit orchestrator registration transport before choosing registration policy
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After the runtime shell, journal, and project-mode read model were in place, the remaining blocker for `slice-003` was not state shape but missing transport: Swift had no runtime-service endpoint or client API for orchestrator registration, stale marking, or clearing outside the in-process FFI seam.
- **Decision:** Add the minimal authenticated runtime-service orchestrator mutation route (`POST /runtime/orchestrator/mutate`) and matching Swift `RuntimeClient` transport now, but stop short of choosing when the app should automatically call it. Registration policy and reconnect behavior remain the next step.
- **Alternatives considered:** Jumping directly to automatic registration from inferred session state was rejected because it risks violating the spec’s “no loose terminal inference” rule. Leaving orchestrator mutation available only via in-process FFI was rejected because the runtime-service control plane would remain incomplete.
- **Consequences:** The explicit registration handshake is now available end-to-end over the runtime service. The next slice should focus on one trustworthy caller and reconnect policy instead of more transport plumbing.
- **Supersedes:** none

## Decision 12: Project-card primary action should reconnect explicit active/stale orchestrators via `claude --resume`
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** Once explicit orchestrator mutation transport existed, the next question was how to use it safely. The project card already needed a reconnect-aware behavior, but any caller that guessed orchestrator identity from tmux state or loose filesystem evidence would violate the architecture target.
- **Decision:** For now, only one caller gets reconnect behavior: the project-card primary action. If the runtime snapshot explicitly says the project is in `active` or `stale_orchestrator` mode and also provides a registered orchestrator `session_id`, the app should resume that Claude session via `claude --resume <session_id>` instead of falling back to generic terminal launch. Pending review still takes precedence and routes to the native review surface.
- **Alternatives considered:** Reconnecting from local Claude metadata without explicit runtime registration was rejected because it would make Swift infer orchestrator identity. Continuing to always open a generic terminal was rejected because it would ignore explicit runtime truth and risk duplicate orchestrator launches.
- **Consequences:** Reconnect behavior now depends on explicit runtime-owned orchestrator identity. Automatic registration policy remains undecided, so only explicitly registered projects get this reconnect path today.
- **Supersedes:** none

## Decision 13: Project-card open flow is the first trustworthy orchestrator registration caller
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After reconnect behavior landed, explicit orchestrator identity still required manual runtime mutation. The remaining question for `slice-003` was which caller could register a project-level orchestrator without letting worker sessions or loose terminal heuristics become orchestration truth.
- **Decision:** The first trustworthy registration caller is the project-card primary action when it falls through to plain terminal open. That user action arms a pending registration for the chosen project, but registration fires only after a later runtime snapshot shows exactly one Claude session whose `project_path` matches the pinned project path exactly. Worktree-derived sessions and ambiguous multi-session exact-path snapshots are intentionally ignored, and repeated identical snapshots must not resend the same registration request.
- **Alternatives considered:** Registering from any active session projected onto the project was rejected because worker sessions in `.capacitor/worktrees/` can map back onto the pinned project. Registering from tmux/tab state or local Claude metadata alone was rejected because it would make Swift infer orchestrator identity outside the runtime boundary. Registering every exact-path session automatically without an explicit user action was rejected because it would make ambient terminal activity silently authoritative.
- **Consequences:** Explicit orchestrator identity now becomes available without manual seeding after the user opens a project and the runtime later observes one exact root-project session. This keeps registration narrow, path-based, and compatible with the runtime-authority rule while leaving broader stale-marking and liveness policy for a later increment.
- **Supersedes:** none

## Decision 14: Mark active orchestrators stale only after consecutive fresh snapshots miss their exact root-project session
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** Once registration became explicit, `slice-003` still lacked a trustworthy way to move an orchestrator from `active` to `stale`. The app already had runtime snapshots with exact session paths, but a single missing snapshot could still be a transient hook gap and worker worktree activity can still project onto the pinned project.
- **Decision:** The first trustworthy stale-marking caller lives in Swift `AppState` alongside the registration coordinator. For an explicitly registered active orchestrator, Swift should watch fresh runtime snapshots and count misses of that orchestrator's exact root-project `session_id`. If the exact session is absent for two consecutive fresh snapshots, Swift sends `mark_stale` through the runtime service. Worktree-only activity does not keep the orchestrator active, and repeated identical miss snapshots must not resend the same stale-mark request.
- **Alternatives considered:** Marking stale from tmux/tab state or shell routing was rejected because those are local heuristics, not runtime orchestration truth. Marking stale after a single fresh miss was rejected because hook/routing gaps can be transient. Treating any project activity, including worktree sessions, as evidence that the orchestrator is still active was rejected because it would let worker activity masquerade as orchestrator liveness.
- **Consequences:** `stale_orchestrator` now has a concrete first liveness policy built on runtime snapshot evidence rather than local guesswork. The next increment can focus on manual smoke coverage and replacement/session-handoff policy when a different exact root-project session appears.
- **Supersedes:** none

## Decision 15: Multi-session project registration should follow the runtime representative session
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** Live AX smoke on `capacitor` proved that long-lived projects accumulate many retained exact root-project session rows. The prior registration rule required exactly one exact-path session in the runtime snapshot, so the project-card open flow kept skipping registration with `reason=ambiguous_exact_sessions count=17` even though the runtime project summary already exposed a single representative session for that project.
- **Decision:** When the project-card open flow arms pending orchestrator registration, Swift should ask the runtime project summary for the project's representative session (`session_id` in the Swift read model, derived from runtime `representative_session_id`) and fall back to the runtime latest session only if the representative is absent. Registration proceeds only if that runtime-selected candidate still appears as an exact root-project session in the same fresh snapshot. Worktree-derived sessions remain ineligible, and repeated identical candidate snapshots must not resend the same registration request.
- **Alternatives considered:** Keeping the exact-count-equals-one gate was rejected because real retained session history already violates it. Re-ranking exact sessions in Swift by timestamps or local terminal heuristics was rejected because it would make the UI a second orchestration authority instead of following runtime-owned project summaries.
- **Consequences:** Long-lived projects can now register an orchestrator from retained exact-path history without manual seeding, while runtime remains the authoritative selector of which root-project session currently represents the project. Replacement/session-handoff policy is still open when a newly launched exact session should supersede an already registered orchestrator.
- **Supersedes:** Decision 13's exact-count registration predicate

## Decision 16: Registered orchestrators should hand off to a new runtime representative session after hysteresis
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** Once registration followed the runtime representative session, the next gap was what to do when a project already had an explicit orchestrator but the runtime project summary later pointed at a different exact root-project session. Waiting for the old session row to disappear is not trustworthy in live data because ready/history session rows are retained, so exact-session disappearance is a poor handoff trigger.
- **Decision:** For a project with an explicit orchestrator, Swift should treat a different runtime-selected exact root-project session as a replacement candidate. If the same candidate remains the runtime representative for two consecutive fresh snapshots, Swift re-registers the project to that new session through the existing `register` mutation. Worktree-derived sessions remain ineligible, and repeated identical candidate snapshots must not resend the same replacement request.
- **Alternatives considered:** Requiring the old registered session row to disappear before replacement was rejected because live retained-history snapshots would make handoff impossible. Replacing immediately on the first representative mismatch was rejected because a single snapshot can still be noisy; the same two-snapshot hysteresis used elsewhere gives a safer boundary. Using local terminal heuristics or tmux evidence to choose the new session was rejected because the runtime project summary already owns that read model.
- **Consequences:** Handoff now stays inside the runtime-authority boundary and works even when old ready session rows linger in history. The remaining open risk is stale-marking: if retained rows also prevent exact-session disappearance from being meaningful, stale liveness may need a similar runtime-summary-based refinement.
- **Supersedes:** none

## Decision 17: Stale-marking should follow fresh exact-session evidence, not mere retained-row presence
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** Live runtime snapshots for `capacitor` and `personality` showed that exact root-project session rows can linger as `ready` history for more than 50 minutes while the orchestrator record still says `active`. Decision 14's disappearance-based rule therefore left dead or at-least-not-fresh orchestrators permanently reconnectable because the registered session row never vanished.
- **Decision:** Replacement still takes precedence: if the runtime project summary points at a different exact root-project session, Swift follows the existing two-snapshot handoff rule instead of stale-marking. Otherwise, the registered exact root-project session now counts as live only if it is still present and either explicitly reports `is_alive = true` or has fresh runtime evidence via `last_activity_at` or `updated_at` within five minutes of the runtime snapshot's `generated_at`. If two consecutive fresh snapshots lack that fresh exact-session evidence, Swift sends `mark_stale`. Worktree-derived sessions remain ineligible, and repeated identical stale-mark requests stay suppressed.
- **Alternatives considered:** Keeping disappearance as the liveness rule was rejected because retained ready/history rows make it ineffective in real data. Using Swift's wall clock was rejected because runtime snapshot generation time is the more authoritative boundary and keeps tests deterministic. Treating any retained exact row as live was rejected because it collapses durable resume identity and live orchestrator freshness into the same signal.
- **Consequences:** Registration and reconnect can still follow a retained exact session when it is the best runtime-owned resume target, but that same retained row no longer keeps the project in `active` forever. The project can settle into `stale_orchestrator` while still reconnecting through `claude --resume <session_id>`, which preserves resume behavior without overstating liveness.
- **Supersedes:** Decision 14's disappearance-only stale predicate

## Decision 18: Missing saved orchestrator conversations should clear and recover, not dead-end reconnect
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After Decisions 12 and 17, stale project cards intentionally remained reconnectable because a retained exact-path Orchestrator session can still be the best runtime-owned resume target. Live user repro showed the remaining gap: a `stale_orchestrator` card for `personality` launched `claude --resume 43cf9cf1-4768-40c8-b32f-662ccc627f58`, but Claude immediately replied `No conversation found with session ID: 43cf9cf1-4768-40c8-b32f-662ccc627f58`. Swift treated "bash launched" as success, so the user hit a dead end instead of recovering.
- **Decision:** Keep stale project cards reconnect-first, but add a negative validation step before launching `claude --resume`. Swift now checks the saved Claude project session metadata under `~/.claude/projects/` for the registered Orchestrator session ID. If that saved conversation is missing, `TerminalLauncher` reports a specific resume-unavailable failure instead of launching `--resume`. `AppState` then clears the unusable runtime Orchestrator registration through the existing `clear` mutation, clears its local stale/read-model state, falls back to the normal Project terminal open, and re-arms Orchestrator registration so the next fresh exact root-project session can become authoritative again.
- **Alternatives considered:** Treating every `stale_orchestrator` card as plain terminal open was rejected because stale and resumable are intentionally separate concepts. Continuing to launch `claude --resume` and rely on the CLI error text in the terminal was rejected because it leaves the user stuck in a dead-end recovery path. Guessing a replacement Orchestrator from tmux state or other local heuristics was rejected because runtime still owns positive Orchestrator identity.
- **Consequences:** Runtime remains the authority for which session is the Orchestrator, while local Claude session metadata is used only as a negative check on whether the already-registered resume target still exists. Stale cards still reconnect when the saved conversation exists, but missing saved conversations now degrade to an explicit clear-and-recover flow instead of a dead-end resume failure.
- **Supersedes:** none

## Decision 19: Project orchestration views should expose the active delegated idea instead of making Swift UI read raw delegation state
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After `slice-004` moved review routing, review detail reads, and review decision submission onto runtime-owned `project_orchestration_views`, one UI residue remained: the project detail idea queue still fetched raw `RuntimeDelegationState` only to answer a narrower question, "which idea is actively delegated right now?" The queue needed that fact to distinguish `delegationWorking` from `reviewReady`, but it did not need the full delegation record.
- **Decision:** Keep the full delegation snapshot as the runtime-owned source record for the delegation-loop side-effect seam, but add a minimal `active_idea_id` field to `ProjectOrchestrationView` when the mode is `active`. Swift queue consumers should use `review_context.idea_id` for `review_needed` and `active_idea_id` for `active`, rather than reading raw delegation state from `AppState`.
- **Alternatives considered:** Leaving the idea queue on raw `RuntimeDelegationState` was rejected because it keeps the UI coupled to a lower-level slice record after the runtime-owned projection already exists. Copying the full delegation record into the orchestration view was rejected because the queue only needs idea identity, and duplicating extra fields would widen the projection without a clear consumer.
- **Consequences:** The remaining Swift `RuntimeDelegationState` usages are now the underlying runtime snapshot and `DelegationLoopManager` reconcile path, not UI/read-model consumers. This keeps the projection additive and consumer-shaped while avoiding opportunistic widening into multi-worker design.
- **Supersedes:** none

## Decision 20: After `slice-004` projection convergence prefer merge-prep and external review over adjacency-driven widening
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After `slice-004` moved review routing, review detail reads and actions, and project-detail queue state onto runtime-owned `project_orchestration_views`, the last obvious Swift UI dependency on raw delegation state was removed. Focused Rust and Swift tests are green, and fixture-backed smoke now proves the native review path plus project-detail navigation under the new projection. What remains is not another clearly named consumer-shaped deletion; it is a higher-level question of whether the current runtime and Swift boundary is clean enough to grow.
- **Decision:** Treat the current branch state as merge-prep territory. Before widening orchestrator behavior again, require either a precisely named obsolete dependency or duplicated source of truth that the next cut will delete in the same slice, or an external review finding that identifies a concrete risk worth addressing. Otherwise prioritize manual smoke, external review packaging, and cleanup.
- **Alternatives considered:** Continuing opportunistic local convergence was rejected because it risks widening the architecture without a crisp deletion target. Declaring `slice-004` fully complete immediately was rejected because the queue badge still lacks a clean direct end-to-end HUD or AX assertion and an external review could still expose coupling that is easy to miss from inside the branch.
- **Consequences:** Future agents should start from proof and cleanup posture rather than "what nearby code can we also move." Additional code motion now needs an explicit deletion target or a reviewer-driven reason, which protects the runtime-owned projection from expanding by accident.
- **Supersedes:** none

## Decision 21: Missing-conversation recovery should quarantine a dead Orchestrator session until runtime clears it
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** Adversarial review of the merge-prep `slice-004` cut found that Decision 18's clear-and-recover flow still had two correctness gaps. `AppState` armed pending Orchestrator Registration immediately, and candidate selection still accepted retained exact root-project session rows. That meant a saved Orchestrator session that local Claude metadata had already disproved could become authoritative again from weaker runtime evidence. A failed runtime `clear` mutation also only logged the failure, leaving the user vulnerable to falling back into the same dead stale Orchestrator path.
- **Decision:** Treat a missing saved Orchestrator conversation as durable negative evidence until the runtime boundary catches up. When `TerminalLauncher` reports `resumeSessionUnavailable`, Swift now records an unavailable-Orchestrator recovery for that Project, suppresses the blocked Orchestrator from the local read model, excludes that exact session from future registration candidates, and gates actual Orchestrator Registration until runtime `clear` succeeds or a fresh runtime snapshot proves the blocked Orchestrator row is gone. If `clear` fails, Swift surfaces an error toast and retries `clear` on later fresh snapshots while the blocked Orchestrator still exists in runtime state.
- **Alternatives considered:** Clearing local UI state once and immediately trusting the next runtime-selected exact session was rejected because retained exact session rows can resurrect the same dead Orchestrator. Treating runtime `clear` as best-effort logging was rejected because it abandons Restart Recovery and leaves the user on a stale dead-end path.
- **Consequences:** Local Claude metadata remains a negative-validation boundary rather than a second positive authority, but once it disproves an Orchestrator session, that session cannot immediately regain authority through weaker retained-history evidence. Missing-conversation recovery is now a small explicit state machine instead of a fire-and-forget side effect.
- **Supersedes:** Decision 18's optimistic re-arm semantics

## Decision 22: Active delegation projection outranks stale Orchestrator metadata
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After Decision 19 added `active_idea_id`, adversarial review found that `project_orchestration_views` still emitted `stale_orchestrator` before `active`. When a stale Orchestrator and a still-working Worker coexisted for the same Project, that precedence hid `active_idea_id` and regressed queue and card behavior even though the more actionable runtime truth was "Delegation Loop still working."
- **Decision:** In the runtime-owned `project_orchestration_views` read model, `review_needed` still takes top priority. Otherwise, active delegation evidence (`working` Delegation state and/or an active Worker Run) now outranks stale Orchestrator metadata. `stale_orchestrator` is emitted only when the Project has no pending Review and no active delegation truth left to surface. Swift consumers should continue to trust `mode = active` plus `active_idea_id` as the authoritative queue/card lifecycle signal even if the explicit Orchestrator record itself is stale.
- **Alternatives considered:** Teaching Swift UI consumers to special-case stale-plus-working combinations was rejected because the bug lived in the runtime projection, not in rendering. Dropping stale Orchestrator metadata entirely was rejected because reconnect and Orchestrator Liveness still matter when no active Worker truth exists.
- **Consequences:** The runtime-owned projection stays consumer-shaped: the most actionable Project lifecycle fact wins, `active_idea_id` remains visible during stale-Orchestrator overlap, and Swift queue/card behavior no longer depends on ad hoc stale-state exceptions.
- **Supersedes:** none

## Decision 23: Keep raw delegation snapshot state at the side-effect seam until a dedicated worker-reconcile boundary exists
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** After the `slice-004` hardening pass, the remaining Swift `RuntimeDelegationState` usage was re-audited before widening the architecture again. The scan showed that raw delegation snapshot state is no longer used by project cards, queue badges, review routing, or review actions. What remains is `AppState` caching the runtime `delegations` array and passing it to `DelegationLoopManager.reconcile(delegations:)`, where Swift performs local worker-side-effect recovery such as session attachment discovery, milestone completion detection, and transition back to `review_ready`.
- **Decision:** Treat `RuntimeDelegationState` as a temporary delegation-loop side-effect seam, not as a current UI or routing split-brain. Do not widen `project_orchestration_views` just to replace `DelegationLoopManager.reconcile(...)` yet. A future slice may delete this seam only when it can name the replacement explicitly, such as a dedicated runtime-owned worker-reconcile projection or a control path that eliminates the need for Swift-side reconciliation altogether.
- **Alternatives considered:** Forcing the current projection to carry low-level worker-reconcile facts now was rejected because it would overstuff a consumer-shaped read model with details only one side-effect seam currently needs. Deleting raw delegation snapshot state from Swift immediately was rejected because it would strand local session-discovery and review-ready recovery behavior without a replacement boundary.
- **Consequences:** Merge-prep posture remains correct: the branch should favor outside review and cleanup over adjacency-driven migration of the remaining raw delegation seam. Future agents now have a sharper bar for further `slice-004` motion: name the replacement worker-reconcile boundary first, then delete the old seam in the same slice.
- **Supersedes:** none

## Decision 24: Keep the remaining file-driven delegation reconcile seam covered by focused Swift tests
- **Date:** 2026-03-17
- **Status:** Active
- **Context:** A merge-prep audit after Decision 23 did not uncover a new correctness bug, but it did expose an evidence gap: the remaining Swift-owned `DelegationLoopManager.reconcile(delegations:)` seam is still responsible for file-driven `working -> review_ready` and `working -> complete` transitions, while the focused Swift tests previously covered session attachment and review submission more than those file-marker transitions.
- **Decision:** Add and keep focused `DelegationLoopManagerTests` that prove `reconcile(...)` emits `review_ready` when the worker publishes `brief.md` and `manifest.json`, and emits `complete` when the worker writes `completion.json`. Treat these tests as required proof for future edits to this side-effect seam until a later slice deletes or replaces it with a runtime-owned boundary.
- **Alternatives considered:** Leaving that seam covered only by manual smoke and broader end-to-end tests was rejected because the side-effect boundary is now intentionally narrow and deserves narrow proofs. Moving the seam immediately into a new architecture slice was rejected because there is still no named replacement boundary to delete the old path in the same cut.
- **Consequences:** Merge-prep now has stronger executable proof around the last Swift-owned file-driven transitions without widening architecture. Future changes to `DelegationLoopManager.reconcile(...)` should start by extending these focused tests rather than relying on broader smoke.
- **Supersedes:** none

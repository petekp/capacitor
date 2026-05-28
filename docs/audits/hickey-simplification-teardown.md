# Capacitor — Rich Hickey Simplification Teardown

> Doc role: `audit` · Generated 2026-05-28 via the `hickey-simplification-teardown` workflow
> (77 agents: 13 subsystem maps + teardowns, 6 cross-cutting lenses, completeness critic,
> 5 gap-coverage passes, 36 adversarial verifications → 24 confirmed / 12 rejected).
> NOT a current-architecture spec. Recommendations are checked against the documented
> invariants (Rust = truth; Swift = projection + side-effects; the authenticated runtime
> service is the live boundary; persisted artifacts are NOT the primary boundary; one owner
> per concept). Findings that "simplify" by breaking an essential invariant are rejected.

---

## 1. Executive Summary

The single biggest decomplecting truth about Capacitor: **the Rust `ingest → reduce → query → snapshot` spine is already the right shape, and almost every real problem is a *second copy of it built somewhere else* — in the Swift WorkBatch cluster, in a hand-written Swift type universe, in a dead Rust "projection" module, and in Swift re-derivations of decisions Rust already made.** The work is not inventing simplicity; it is deleting the imitations so the one good spine is the only owner.

Ranked by impact ÷ effort (confirmed findings only):

1. **Delete the dead parallel pipelines in Rust (`projection/`, `observation_journal`, `relocate.rs`, `mutate_idea`/`mutate_worktree` stubs).** Zero production callers, several hundred LOC + unsafe FFI removed, eliminates the "which pipeline is real?" tax. *High impact / small effort / low risk.*
2. **Delete the dead FFI-to-string re-serialization island in `RuntimeClient.swift` (~300 LOC).** `SnapshotPayload(_ snapshot: AppSnapshot)` at line 760 and its converter tree have **zero non-bridge callers** (verified). Pure dead-code excision. *High / small / low.*
3. **Split `snapshot_version` into `change_version` + `disk_format_version`.** One u64 field carries the change counter across FFI but the schema constant on disk; `core_query.rs:8` overwrites one with the other. A latent correctness hazard fixed by giving each concept a name and an owner. *High / medium / medium (FFI regen).*
4. **Collapse the 11-method `lock → mutate → bump → snapshot → persist` epilogue into one `commit` combinator** and fix the already-divergent bump-on-ok guard. *High / small / low.*
5. **Move `mutate_project`'s inline reducer logic into `reduce::project`.** It is the lone mutation that mutates `state.projects/delegations/sessions` directly inside the FFI facade. *High / medium / low.*
6. **Restore Rust as the single owner of setup-readiness.** Rust computes `all_ready`/`blocking_reason`, ships them over FFI, and Swift *ignores them* and re-decides. Add new auto-repairable classification to Rust; delete Swift's `startupDecision`. *High / medium / medium.*
7. **Carry typed enums (RunStatus, DelegationStatus, RoutingStatus, SessionState) across the wire instead of `String`,** killing ~30 string-literal if-ladders scattered across the Swift projection layer. *Medium-high / medium / low.*
8. **The WorkBatch redesign is the largest prize but the most nuanced** — hold the per-project state as one in-memory value (delete the load-mutate-save-per-op file thrashing) and derive `status`/`summary` as a pure projection. Do NOT wholesale-relocate it into Rust (rejected — see §7). *High / large / medium.*

---

## 2. Hickey Scorecard

### Where Capacitor already embodies SIMPLE (genuinely, not faintly)

- **The Rust reduce spine is the in-repo reference model.** `ReducerState::snapshot()` (`reduce/mod.rs:291-353`) produces one immutable `AppSnapshot` value; sub-reducers (`run_reducer.rs:38-63`, `delegation.rs`, `session.rs`) are pure functions dispatched by a data-driven `match` on the mutation kind. Values in, value out. This is the bar everything else should be measured against.
- **The service/storage/boundary layer has no interior mutability.** No `Mutex`/`RefCell`/`Arc` in `runtime/boundaries.rs`, `runtime/storage.rs`; persistence is produce-new-value + atomic rename, not in-place mutation. `find_project_boundary`, `encode_path`/`decode_path`, `validate_project_path` are pure total functions. The `TokenGuard` RAII and credential `chmod`-verify are *essential* security complexity, correctly localized.
- **`HookIssue` (`runtime/types.rs:352-366`) is polymorphism-a-la-carte done right** — `PolicyBlocked{reason}`, `SymlinkBroken{target,reason}`, `NotFiring{last_seen_secs}` carry their data in the variant; the decision is the value, dispatch is separate.
- **The FFI data surface is 147 plain-data structs + 27 enums + exactly ONE object** (`CoreRuntime`, the opaque stateful handle — essential). Plain values across the seam matches the event-sourced model.
- **Swift `RuntimeSnapshotApplicator.apply()` returns `Outcome{Decision, [Effect]}`** with effects described partly as data — a good shape (with one honest caveat, see §4).
- **`WorkBatchDeliveryPolicy.decide`, `WorkBatchProjectionBuilder.build`, the `*Resolver` enum namespaces, the `TerminalDriver` protocol + `SupportedTerminalApp` closed enum, and `SetupRequirements`' event-sourced `apply(_ event:)`** are all pure transforms / a-la-carte dispatch — local exemplars.
- **The `method_runner` event→project→state spine** (`state.rs:297 project()`, torn-tail recovery, FSM legal-edge tables) is genuinely value-oriented and is the authoritative source of truth for a resumable out-of-process worker — *essential* complexity, correctly built.

### Where Capacitor COMPLECTS

- **Parallel owners across the Rust/Swift seam.** Setup-readiness decided 2× (Rust verdict ignored, Swift re-derives). Status meaning re-parsed from strings ~30×. The workspace_id join key and path normalization implemented 3-4× with *different canonicalization strategies* — a silent-drift hazard on the primary join key.
- **A whole shadow spine.** WorkBatch reimplements ingest/reduce/query/project imperatively in Swift, using the filesystem as its working store (load-mutate-save per op), with `status`/`summary` mutated in place across two owners (router + reconciler) and a `WorkBatchClaudeProcessScanner` that scrapes `ps`/`lsof` instead of reading the authenticated runtime service.
- **Three type universes for one set of facts.** Rust serde+uniffi (one source, two codegen projections) vs. hand-written Swift `Snapshot*Payload` + `Runtime*` Decodable mirrors — plus a dead FFI-to-string converter strand.
- **Place-oriented `state_version`/revision counters** substituting for value-derived change detection, and `snapshot_version` overloaded with three meanings.
- **Dead scaffolding masquerading as architecture** — `projection/`, `observation_journal`, `relocate.rs`, stub mutations — that makes a reader unable to tell the real spine from the imagined one.

---

## 3. System Census — Moving-Parts Inventory

Verified counts in `apps/swift/Sources/Capacitor/` (type-declaration grep, deduped):

| Kind | Count | Notes |
|---|---|---|
| Store | **16** | Highest. 5-6 are near-identical JSON-directory codecs (WorkBatch). |
| Projection | 13 | Several are derivation logic living in the View tree. |
| Resolver | 12 | Mostly stateless `enum` namespaces — already the right shape. |
| Policy | 9 | Includes ActivationPolicy, the two re-derivations, WorkBatchDeliveryPolicy (good). |
| Coordinator | 8 | |
| Manager | 4 | |
| Builder | 4 | |
| Router | 2 | TmuxRouter (essential) + WorkBatchAutoRouter (2,349 LOC god-object). |
| Reconciler | 1 | WorkBatchBindingReconciler (parallel owner of status). |
| Projector | 1 | WorkBatchPreviewProjector. |

`apps/swift/Sources/Capacitor/Models/` alone holds **67 files**. Rust core ships a `lib.rs` facade with **zero public functions** — the real `CoreRuntime` impl lives in `core_ingest.rs` (393 LOC), `core_query.rs`, `core_serve.rs`, `core_lifecycle.rs`, `core_gc.rs`. The split is sound partitioning (one object across files), *not* indirection — keep it, but rename `core_serve.rs` → `core_diagnostics.rs` (it holds hook-health/diagnostics, no serve dispatch) and move the idea-CRUD pass-throughs out of `core_ingest.rs`.

**Top collapse candidates:** (1) the 5 WorkBatch `*Store` structs → one generic codec; (2) the 11 CoreRuntime commit epilogues → one combinator; (3) the dead Rust `projection/` + `observation_journal` + `relocate.rs` → deletion; (4) the dead Swift FFI converter island → deletion; (5) WorkBatchAutoRouter's 2,349 lines → coordinator + pure status deriver + side-effect lane.

---

## 4. Findings by Theme

### A. Moving Parts — dead scaffolding to delete (highest payoff, lowest risk)

**A1. The Rust `projection/` + `observation_journal` modules are fully-built, exported, tested *dead* scaffold.** `SnapshotReadModelProjector::project()` literally does `snapshot.clone()` + `observations.len()`; the only callers are `tests/replay_diff.rs`, which assert a clone equals its input. `ObservationJournalStore` is a 2-method trait with one in-memory impl that nothing in `CoreRuntime` ever appends to. **Verified:** grep for these symbols outside the modules themselves and their tests returns nothing.
- *Braid:* future-capability complected with present-truth — a fake imitation of the real spine.
- *Decomplected design:* delete `projection/mod.rs`, `storage/observation_journal.rs`, `ObservationRecord`/`ObservationPayload`/`ObservationSourceKind`, the `storage/mod.rs` re-exports, and rewrite the ~3 replay_diff tests to assert on the real `AppSnapshot` they already compute. Reintroduce a journal *only* when wired to a real append point.
- *Effort: medium. Risk: low (no production caller). Invariant: strengthens single-owner; the genuine `snapshot()` projection remains.*

**A2. `relocate.rs` is a complete, tested, dead subsystem with unsafe libc FFI.** `runtime/mod.rs:9 pub mod relocate;` is the only reference; both functions carry `#[allow(dead_code)]` (verified). ~155 LOC including `unsafe libc::open/fcntl`.
- *Decomplected design:* delete the module + the `pub mod` line. The `.project_path` sidecar already provides simpler, portable relocation. *Small / very low / shrinks unsafe-audit surface.*

**A3. `mutate_idea` / `mutate_worktree` are STUB FFI methods that fake success.** Doc comments literally say "does not yet mutate model state" (`core_ingest.rs:233,255`, verified). They bump `events_ingested`, call `bump_version_and_notify()`, and persist a full snapshot — firing a no-op long-poll wake and a wasted disk write — to return `ok:true` having changed nothing. Real idea state lives in `runtime::ideas`; worktrees flow through hook events.
- *Decomplected design:* delete both methods + `MutateIdeaCommand`/`IdeaMutationKind`/`MutateWorktreeCommand`/`WorktreeMutationKind`, regenerate bindings. *Small / low.* This also corrects a `state_version`-as-time lie: a version bump must imply the value changed.

### B. State / Value / Time

**B1. `snapshot_version` complects three meanings behind one field — confirmed correctness hazard.** `reduce/mod.rs:350` stamps it with `CURRENT_SNAPSHOT_SCHEMA_VERSION` (=1). `core_query.rs:8` then *overwrites* it with `self.version.load()` (the AtomicU64 change counter) before crossing FFI. `storage/mod.rs:205` quarantines on `!= CURRENT_SNAPSHOT_SCHEMA_VERSION`. Swift's applicator does ordered `<`/`max` comparisons treating it as a change counter. The disk gate is only correct today because the disk write always re-stamps (line 242) whatever the counter was.
- *Decomplected design:* add `change_version: u64` (owned solely by the AtomicU64, set once in `app_snapshot()`, never persisted as truth) and rename the disk field `disk_format_version` (owned solely by storage, used only for quarantine). Two names, two owners, zero overwrite.
- *Effort: medium (FFI Record shape → regen `capacitor_core.swift` + update hud-hook JSON + Swift decoders in one commit). Risk: medium. Invariant: strengthens single-owner; persisted artifacts stay non-primary.*

**B2. The 11-method commit epilogue is copy-pasted with an *already-divergent* guard.** Every mutation re-types `lock → apply_X → bump → snapshot → drop → persist`. **Verified divergence:** `apply_shell_unregister` guards `bump_version_and_notify()` behind `if outcome.ok` (`core_ingest.rs:48`) while `apply_hook_event` (`:12`), `apply_shell_signal` (`:131`), `apply_delegation_mutation` (`:281`), and `mutate_run` (`:294`) bump *unconditionally*. That is invisible drift: a rejected mutation currently still wakes long-pollers.
- *Decomplected design:* one private `fn commit<F: FnOnce(&mut ReducerState) -> MutationOutcome>(&self, f) -> Result<MutationOutcome>` that locks once, runs the closure, applies ONE documented bump-on-ok rule, snapshots, drops, persists. `mutate_run_with_commit` becomes a `try_commit` variant with rollback (it already hand-rolls this at `:64-82`). Keep `run_gc_at` separate — its no-op-tick skip of persist+log is intentional.
- *Effort: small (no FFI signature change). Risk: low — but the bump-on-ok reconciliation is a *deliberate behavior choice*; cover with a test asserting a rejected mutation does NOT bump `snapshot_version`.*

**B3. The applicator shreds one `AppSnapshot` into 6 stores — but do NOT collapse to one mirror.** `RuntimeSnapshotApplicator.apply()` fans the immutable snapshot into `sessionStateManager`, `shellStateStore`, `routingStateStore`, `runState` (×2), `uiState`. The adversarial verdict **rejected** the "one `AppliedSnapshot` value" redesign: `SessionStateManager` deliberately diverges from the incoming snapshot via hysteresis (it holds prior values + per-project counters), `RunStateStore` accepts local optimistic mutations, and `apply()` is `@MainActor`-synchronous so no observer sees a half-update. *Confirmed-but-narrowed:* the only safe move is compute-then-commit batching, not a unified value. The six stores own genuinely-different slices.

**B4. Manual revision counters partly substitute for value change-detection.** `workBatchProjectionRevision` is a real workaround: `WorkBatchAutoRouter` is *not* `@Observable`, so `workBatches(for:)` does `_ = workBatchProjectionRevision; return router.projections(for:)` to force recompute. `sessionStateRevision` is largely *vestigial* — `SessionStateManager` is already `@Observable` and views read `.sessionStates` directly. *Decomplected design:* make `WorkBatchAutoRouter` `@Observable` with a published projections cache, then delete `workBatchProjectionRevision`; verify-then-delete `sessionStateRevision`. **Keep** the request-arbitration generation counters (`requestGeneration`, `applyGeneration`) — those address essential concurrency.

### C. Parallel Owners (the documented NON-GOAL)

**C1. Setup-readiness is decided on both sides; the Rust decision is dead.** Rust's `check_setup_status` computes `all_ready`/`blocking_reason` (`setup/mod.rs:101-146`) and ships them over FFI — **grep confirms zero non-bridge Swift readers.** Swift's `SetupReadinessCoordinator.startupDecision` re-derives the 3-way gate (ready / welcome / auto-repair) from raw `dependencies` + `hooks`.
- *Decomplected design:* Rust's current binary `all_ready` + flat string can't drive the 3-way gate, so **add** a `SetupReadiness { Ready | NeedsUserAction{reason} | AutoRepairable{status} }` enum classifier in Rust; delete Swift `startupDecision`; App.swift switches on the Rust enum (Swift still owns *which* side-effect to run). Write a characterization test over every `HookStatus` variant first (the load-bearing rule: only `claudeMissing` + `policyBlocked` hold setup; everything else auto-repairs). **Leave** `SetupRequirements.allComplete` alone — that's per-step wizard UI projection, a different surface, not a fourth copy. *Medium / medium.*

**C2. The workspace_id join key + path normalization drift across 3-4 implementations.** `workspace_id` (MD5 join key tying sessions↔routing↔projects) computed in Rust `domain/identity.rs:118` and independently in Swift `WorkspaceIdentity.swift`. Path normalization has three *different* strategies: Rust string-trim+lowercase, hud-hook `fs::canonicalize`, Swift `resolvingSymlinksInPath`. They are not guaranteed to agree — a one-symlink disagreement silently detaches sessions from projects (mitigated today only because path-containment fallbacks usually rescue it).
- *Decomplected design:* **Phase 1 (cheap):** a Rust↔Swift conformance test over a fixture corpus (symlinks, trailing slashes, case) — makes drift loud without restructuring. **Phase 2:** add `workspace_id` to the UI `Project` FFI record (currently absent), join on the Rust-provided key, converge the canonicalizers (ideally export `normalize_path_for_matching` via UniFFI). *Medium / medium.*

**C3. ActivationPolicy — REJECTED as a parallel owner.** The adversarial verdict found `ActivationPolicy.resolveIntent` is NOT re-deriving routing: it produces the *activation intent* (which terminal app to drive, with `.runtimeRoute`/`.fallback` provenance), merges a caller-supplied `sessionName` that wins over the route, and calls `detectAvailable()` — a live macOS query Rust cannot do. The fallback and its provenance are irreducibly Swift-side. **Do not move this into Rust** (it would push an NSWorkspace side-effect across the boundary). The only defensible cleanup is decoding the stringly-typed `kind`/`status` into Swift enums (folds into C-theme below).

**C4. `SessionResolutionPolicy.sessionNameBelongsToProject` is a dead string-similarity heuristic** (33 LOC + magic `genericSessionNames` set; only test callers, verified). Confirmed-but-severity-medium (it's *latent*, not active). *Delete it + `genericSessionNames` + their tests; keep `chooseSessionName` which correctly defers to the Rust-resolved route. Small / low.*

**C5. Liveness + Working→Ready demotion — REJECTED as written, refined.** The verdict found Rust `is_alive` is *event-decay-based* (`gc.rs`), so a quiet-but-live cockpit can decay to `is_alive=false` while the OS process is up. Swift's `SessionStaleness`/process-probe sees that gap. Collapsing Swift's display `.ready` into Rust's persisted `.idle` would conflate two distinct concepts and delete essential projection. *Refined:* if OS liveness is wanted as truth, emit it from hud-hook (which already does process probing via `sysinfo`), not from a Swift `ps`/`lsof` scrape — but the Working→Ready *display* transition stays Swift-side.

### D. Data vs Objects

**D1. The dead FFI-to-string re-serialization island (~300 LOC).** `RuntimeClient.swift:760 init(_ snapshot: AppSnapshot)` + ~21 `init(_ ffiType:)` converters + 8 enum→string converters (`snapshotSessionStateString` etc.) + a `Mirror`-reflection helper. **Verified:** the converter root has zero non-bridge callers — the live path is HTTP JSON decode; the in-process FFI snapshot path is never invoked. *Decomplected design:* delete the entire encode strand; keep the `Decodable` wire DTOs and `mapNNN` functions. *Small / low.* This collapses the apparent "third type universe" toward two.

**D2. Three type universes for one set of facts — narrowed.** The verdict corrected the premise: Rust already has **one** source (`domain/types.rs` derives both `serde` and `uniffi::Record`). The genuine duplication is the hand-written Swift `Snapshot*Payload`/`Runtime*` mirror. *Decomplected design (after D1):* either keep hand-written DTOs (acceptable — they're stable and the wire JSON is the documented boundary) or generate them from the Rust serde schema. Do **not** route Swift tracking reads back through in-process FFI (violates ADR-004). The high-value, certain win is D1's deletion.

**D3. The 5-6 WorkBatch `*Store` structs are one codec wearing different type hats.** `WorkBatchTaskRequestStore`/`TaskClaimStore`/`CompletionReportStore`/`CheckpointRequest/ResponseStore` share identical init/`directoryURL`/load/write; they differ in 4 data points (dir name, type, predicate, filename rule). **Confirmed smoking gun:** `WorkBatchTaskClaim.swift:45 claimURL` borrows `WorkBatchCompletionReportStore.reportFileName`, and `WorkBatchCheckpointExchange.swift:137` borrows another store's `fileName` — cross-store coupling from copy-paste.
- *Decomplected design:* one shared codec factory (the `[.prettyPrinted,.sortedKeys]/.iso8601` encoder + `.capacitorISO8601` decoder + one filename sanitizer) applied to all stores, plus a `JSONDirectoryStore<T: Codable>` for the directory-of-records family. **Caveat (from verdict):** the response store is write-only and the completion store's `deleteReport` does a dedup rescan — model operations as opt-in capabilities, don't force a uniform load/write/delete triad. Net ~3-4 structs removed; the durable win is the shared codec.
- *Effort: medium. Risk: low. These are worktree-local `.capacitor/` artifacts, not the runtime boundary.*

**D4. `MutateRunCommand` is a ~30-field god-command.** One flat struct carries the union of all 16 `RunMutationKind` payloads; the reducer reads only 2-4 per kind, callers spell out ~26 `None`s. *Decomplected design:* an enum-with-fields per kind (the codebase already uses `CheckpointKind::Custom{label}`). On the Swift side, **Tier 1 (safe now):** per-kind static factory constructors that fill the nils internally (kills the 22-nil call sites with no wire change). **Tier 2 (Rust-first):** the sum type, regen bindings. *Tier 1 small/low; Tier 2 large/medium — sequence behind cheaper wins.*

### E. Conditional Dispatch / Abstraction

**E1. RunStatus/DelegationStatus/SessionState cross as `String`, spawning ~30 re-parsing ladders.** Rust owns the enums (`run_types.rs:15`, `domain/types.rs:203`), UniFFI generates typed mirrors, but the JSON path carries bare strings, and Swift re-discovers semantics in if-ladders across ~9 files (`ProjectRunVisualStateResolver` duplicates the full ladder in `visualState()` *and* `priority()`). Confirmed drift: `created` means "running" in one resolver, invisible in another, omitted elsewhere.
- *Decomplected design:* decode `status` into a Swift enum once at the `RuntimeClientTypes` boundary (the `SessionState`/`RunStatus` round-trip is *Swift-to-Swift* — `RuntimeRunState` is built from the typed UniFFI value then stringified; just stop stringifying). Replace `== "..."` with exhaustive `switch`. Centralize run→`RunVisualState` in one resolver. Make decode of an unknown value *throw* rather than coercing to `.idle`/`.pending` (the current lossy defaults silently swallow version drift). *Medium / low.* Keep the time-window staleness predicates (`isPausedCheckpointStale`, `isRunFreshnessExpired`) in Swift — essential projection.

**E2. SessionState display attributes re-declared in ~5 view files.** label/description/accessibility/telemetry switches scattered; confirmed bug — the *same* state has two different accessibility descriptions with nothing forcing agreement. *Decomplected design:* one `SessionState.presentation` extension returning a value struct; views read attributes. **Scope down:** statusColor/flashColor are already centralized in `Colors.swift` — leave them; and do NOT touch behavioral switches (priority bucketing, attention authority, layer-opacity) — those are essential, consumer-specific decisions. *Small.*

**E3. `verify_hook_binary` string-packs `SYMLINK_BROKEN:target:reason` then `splitn`-parses it back** (`setup/deps.rs:83-94,137-188`), with a duplicated symlink pre-check. *Decomplected design:* a private `enum BinaryProbeError`; match on it. Also collapse `HookSettingsStatus` into `HookStatus` (the only difference is a dead `Installed{version:"binary"}` payload Swift never reads). *Small / low.*

### F. Parallel-owner spotlight: WorkBatch (cross-cutting, see §5)

The status/summary in-place mutation by two owners (router `mark*` helpers + reconciler `mark*` helpers, ~49 `.status = .` sites), the `shouldReplaceSummary*` string-sniffing that reverse-engineers state from UI prose, and the load-mutate-save-per-op filesystem thrashing are the concentrated debt. Treated as a system theme below because the right fix is bounded and the wrong fix (relocate to Rust) breaks invariants.

---

## 5. Cross-Cutting Themes & Redesign Sketches

**T1 — One spine, many imitations.** The Rust `ingest→reduce→query→snapshot` model is correct and should be the *only* such pipeline. Delete the dead Rust `projection/`/`observation_journal` (A1), and reshape — not relocate — WorkBatch to follow it Swift-side.

**T2 — WorkBatch: reshape in place, do NOT relocate to Rust.** Two adversarial verdicts **rejected** the "move WorkBatch ingest/reduce/policy into Rust reducers" redesign: (a) classification *shells out to `claude --print --model haiku`* — a macOS/process side-effect the event-sourced Rust reducer must not perform (and "never call the Anthropic API directly" is an invariant); (b) the worktree JSON files are an **agent↔app IPC contract** (the in-session `claude` agent writes them with its Write tool), not a snapshot-as-truth boundary; routing them through the service would force the agent into token-discovery + authenticated HTTP. The sound, invariant-respecting redesign is Swift-internal:
  - Hold one in-memory `WorkBatchStateSnapshot` per project as the working value; disk becomes a write-behind sink (delete the per-call `stateStore.load()` + the defensive re-load after the classifier `await`).
  - Make `status`/`currentActivitySummary` **derived projections** computed by one pure `deriveBatchPresentation(...)` (next to the existing `WorkBatchProjectionBuilder.build`), not mutated-in-place by router + reconciler. The `shouldReplaceSummary*` string-sniffing evaporates because summary is recomputed, never patched. Persist explicit reason/outcome enums for the cases summary currently smuggles (duplicate-cockpit, pickup-timeout).
  - Relocate the 5 `*Store` structs to one generic codec (D3).
  - If OS-process liveness is genuinely needed beyond event-decay `is_alive`, emit it from **hud-hook** (the owning side), then delete `WorkBatchClaudeProcessScanner` and the synthetic `"<id> (duplicate process)"` marker — sequenced *after* the service emits the fact.

**T3 — Decode once at the boundary.** Every "stringly-typed status / String wire field re-parsed N times" finding (E1, C2, D2) is the same braid: a typed value flattened to a string at the seam and re-typed by hand downstream. The systemic fix is "decode into a typed value once at `RuntimeClientTypes`, switch exhaustively after."

**T4 — One commit protocol, one owner of mutation.** B2 + the `mutate_project` move converge CoreRuntime on: facade is a thin `commit(|s| s.apply_X(...))` shell; all state transitions live in `reduce/`.

**`mutate_project` (confirmed):** verified to `match command.kind` and call `state.projects.insert/remove`, `state.delegations.remove`, `state.sessions.retain` directly in the FFI facade (`core_ingest.rs:138-229`). Add `reduce::project::apply_project_mutation` mirroring `apply_delegation_mutation`; lift verbatim first. Drop the "fixes a correctness gap via recompute" framing — the verdict found that's likely *not* a bug (recompute is session-driven and a rename touches no session). Sell it as a pure structural single-owner restoration. *Medium / low.*

---

## 6. Decomplecting Roadmap (sequenced: low-risk/high-payoff first)

**Phase 0 — Pure deletions (no behavior change, no FFI regen except where noted).**
1. Delete `projection/` + `observation_journal` + rewrite ~3 replay_diff tests (A1).
2. Delete `relocate.rs` + `pub mod relocate` (A2).
3. Delete the dead FFI converter island in `RuntimeClient.swift` (D1).
4. Delete `mutate_idea`/`mutate_worktree` stubs + their command types; regen bindings (A3).
5. Delete `SessionResolutionPolicy.sessionNameBelongsToProject` + `genericSessionNames` (C4).
6. Rename `core_serve.rs` → `core_diagnostics.rs`; move idea-CRUD out of `core_ingest.rs`.

**Phase 1 — Internal Rust consolidation (no FFI signature change).**
7. The `commit` combinator + bump-on-ok reconciliation, test-first (B2).
8. `reduce::project::apply_project_mutation` move (T4).
9. `BinaryProbeError` enum + `HookStatus`/`HookSettingsStatus` merge (E3).

**Phase 2 — Boundary typing (require FFI regen; ship `capacitor_core.swift` in same commit).**
10. Split `snapshot_version` → `change_version` + `disk_format_version` (B1). *Depends on: regen discipline.*
11. Decode typed enums at the wire boundary; kill the if-ladders + lossy defaults (E1, then D2/C-routing-enum).
12. `SessionState.presentation` consolidation (E2).
13. Setup-readiness `SetupReadiness` enum in Rust; delete Swift `startupDecision`; characterization test first (C1).

**Phase 3 — WorkBatch reshape (largest, Swift-internal).**
14. `WorkBatchAutoRouter` → `@Observable`; delete `workBatchProjectionRevision` (B4).
15. In-memory per-project working value; disk as write-behind (T2).
16. `deriveBatchPresentation` pure projection; delete `mark*` mutators + `shouldReplaceSummary*` (T2/F).
17. Generic `JSONDirectoryStore` + shared codec factory (D3).
18. *Only after hud-hook emits OS liveness:* delete `WorkBatchClaudeProcessScanner` (C5).

**Phase 4 — Cross-language identity hardening.**
19. workspace_id conformance test (C2 Phase 1), then add `workspace_id` to the `Project` FFI record + converge canonicalizers (C2 Phase 2).

**Phase 5 — Optional / largest blast radius.**
20. `MutateRunCommand` sum type, Rust-first (D4 Tier 2). Do Tier 1 (Swift factories) opportunistically in Phase 2.

Dependencies: B1/E1/C1 share the FFI-regen ritual — batch them. T4's `commit` (step 7) should land before step 8 so `mutate_project` uses it. WorkBatch steps 14→17 are strictly ordered.

---

## 7. What NOT To Change (essential complexity & rejected "simplifications")

**Essential complexity to preserve:**
- `SessionStateManager` hysteresis/stabilization (multi-signal authority + per-project debounce counters, ADR-005) — temporal smoothing is essential, not place-oriented waste. Lift only the counter *storage* into one explicit `StabilizerState` value if desired; keep the policy verbatim.
- `method_runner`'s own event log + `project()` + FSM + torn-tail recovery — a resumable out-of-process worker is a genuinely distinct aggregate; it reports milestones into the reduce-spine via the clean `RunStatusReporter` seam. Do NOT merge its event types into `reduce/`.
- The `TokenGuard` RAII, credential `chmod`-verify, three-tier discovery fallback, bootstrap version-skew guard — security/version-skew essentials.
- The `TerminalDriver` protocol + per-terminal drivers — per-terminal automation surfaces genuinely differ; do not flatten.
- FFI marshaling and the `CoreRuntime` opaque handle — inherent boundary cost; the checked-in `capacitor_core.swift` + `check-uniffi-bindings.sh` drift-guard is the correct, minimal mitigation.
- The two path encoders (`projects.rs::encode_project_path` mirrors **Claude's** `~/.claude/projects/` directory format; `StorageConfig::encode_path` owns **Capacitor's** `~/.capacitor/`) — they encode *different external/internal directories* and must NOT be merged (would break transcript discovery). Rename for clarity only.

**Explicitly rejected "simplifications":**
- ❌ **"Move WorkBatch into the Rust reducer."** Breaks "never call the Anthropic API directly" (classification is a `claude` CLI subprocess) and would create a parallel policy owner by splitting LLM-routing (Swift) from reduce (Rust). The worktree JSON is an agent↔app IPC contract, not snapshot-as-truth.
- ❌ **"Route Swift tracking reads back through in-process FFI to delete the DTOs."** Violates ADR-004 (the authenticated runtime service is the live boundary).
- ❌ **"Collapse the 6 applicator stores into one `AppliedSnapshot` value."** Would erase hysteresis, local optimistic mutations, and per-slice observation; `apply()` is already synchronous so the "mid-update observation" motivation is moot.
- ❌ **"Move ActivationPolicy / Working→Ready demotion / OS-liveness into Rust."** Pushes macOS side-effects (NSWorkspace, `detectAvailable`) and event-decay-vs-OS-truth display semantics across the boundary the wrong way.
- ❌ **"Delete the worktree file-drop channel for a service endpoint."** The agent's reliable primitive is writing a file; the genuinely-incidental piece is only the `.git/info/exclude` mutation, removable by relocating stores to `~/.capacitor/`.
- ❌ **"Demote all 39 Resolver/Policy namespaces to free functions."** 25 are *already* caseless `enum` namespaces (= free functions grouped by domain); the OO-wrapper claim was false. The `claude`-CLI-invoking ones must stay Swift-side.

---

## 8. Coverage & Confidence

**Independently re-verified against source** (this synthesis): the commit-epilogue duplication and divergent bump-on-ok guard (`core_ingest.rs`); the `mutate_idea`/`mutate_worktree` stubs; `mutate_project`'s direct map mutation; the dead `SnapshotPayload(_ snapshot: AppSnapshot)` converter (zero non-bridge callers); 14 WorkBatch files / 2,349-line AutoRouter / zero Rust WorkBatch references; the `snapshot_version` overwrite chain (`core_query.rs:8` clobbers the schema constant from `reduce/mod.rs:350`, quarantined at `storage/mod.rs:205`); the `ps`/`lsof` scanner; dead `projection`/`observation_journal` modules; `relocate.rs` `#[allow(dead_code)]`; the system census (67 Models files; 16 Stores / 13 Projections / 12 Resolvers / 9 Policies).

**High confidence (verified + adversarially confirmed):** A1, A2, A3, B1, B2, C1, C4, D1, D3 (with capability caveat), the `mutate_project` move, E1.

**Medium confidence (real but scope/sequencing-sensitive):** B4, C2, C5 (sequence behind hud-hook emitting liveness), T2 WorkBatch reshape, E2 (scope down), D4.

**Rejected by adversarial review (do not action):** the WorkBatch→Rust relocation; the unified `AppliedSnapshot`; ActivationPolicy/liveness/project-aggregation as parallel owners (these are correct Swift projection + side-effect ownership); the "three independent representations / serde drift" framing (Rust is already single-source — only the hand-written Swift mirror and the dead converter are real); the broad Resolver-namespace demotion.

**Caps / not deeply examined (workflow limits — surfaced honestly, not silently dropped):**
- Two agents (one subsystem teardown, one cross-cutting lens) failed to return structured output, so one Swift subsystem slice and one lens are thinner than the rest.
- Verification was capped at the top 40 of the prioritized claim set; gap-coverage at 6 of 10 critic-identified areas (4 uncovered).
- The 20k+ LOC of `Views/` beyond the `*Projection`/`*Resolver` files surfaced here; the Theme/GlassConfig layer and Metal shader (low architectural stakes; GlassConfig should get a data-vs-objects pass); `bin/method_runner.rs` (708 LOC entrypoint) and `ClaudeCliResolver` CLI-resolution parity; test-suite density as a complexity heatmap (`method_runner` has ~20 dedicated test files — a signal it carries the most essential complexity in the repo, reinforcing "do not merge its spine").

**Net:** the highest-leverage work is **deletion of dead imitations of the spine** (Phase 0–1, low risk) and **typing the boundary** (Phase 2). The WorkBatch reshape is the largest structural prize but must stay Swift-internal; treating it as a Rust migration is the single most tempting and most invariant-breaking mistake available.

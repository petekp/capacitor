# Review: Pipeline Design v2

## 1. Addressed Findings Assessment

### 1. Path coupling
- Original concern: execute needed a first-class `--root` with every relay path derived from it.
- Was the fix applied in v2? Yes, substantially. v2 makes `update-pipeline.sh` root-first, requires `update-batch.sh` and `compose-prompt.sh` to become root-first, and explicitly forbids deriving relay paths by guessing from `batch.json` (`.pipeline/design-v2.md:81-86`, `.pipeline/design-v2.md:434-544`).
- Does it fully resolve the concern? No. The design still stores `pipeline_root`, `relay_root`, and all example artifact paths as relative values like `.pipeline/...` (`.pipeline/design-v2.md:96-120`, `.pipeline/design-v2.md:167-173`, `.pipeline/design-v2.md:387-408`). That still makes path resolution depend on the caller's working directory or repo mount point, which contradicts the claim that resume never infers a root from cwd (`.pipeline/design-v2.md:86`, `.pipeline/design-v2.md:627`). The current manage-codex skill and templates also remain hard-coded to `.relay/...`, and v2 does not yet define the templating/substitution contract that turns those static strings into rooted paths (`~/.claude/skills/manage-codex/SKILL.md:21-32`, `~/.claude/skills/manage-codex/SKILL.md:72-98`, `~/.claude/skills/manage-codex/references/relay-protocol.md:7-24`).
- Does it introduce new problems? Yes. The design now has two raw roots, `pipeline_root` and `relay_root`, but only string-equality validation. Without canonicalization, symlinked paths, relative invocation, or mixed repo entrypoints can produce logically identical but textually different roots.
- Grade: `PARTIALLY_RESOLVED`

### 2. `state.json` bloat
- Original concern: `state.json` needed to become a thin index, with per-phase detail moved elsewhere.
- Was the fix applied in v2? Yes. v2 moves phase detail into `phases/{id}/phase.json` and keeps `state.json` to active pointers plus a child-workflow summary (`.pipeline/design-v2.md:88-146`, `.pipeline/design-v2.md:148-264`).
- Does it fully resolve the concern? Yes for the stated design goal. The sample v2 shape serializes to about 1035 bytes with full 64-character hashes, and still only about 1205 bytes when the same fields are expanded to absolute repo-rooted paths. That is comfortably below the stated 2048-byte cap.
- Does it introduce new problems? Not as a size problem. There is still summary duplication between `state.json` and `phase.json`, but that is an authority/synchronization issue, not bloat.
- Grade: `RESOLVED`

### 3. Pointer immutability
- Original concern: completed-phase artifact pointers needed content hashes and locking so later edits could not silently rewrite history.
- Was the fix applied in v2? Yes, partially. v2 adds `sha256`, `lock_state`, `locked_at`, `phase_completed` lock events, and cold-resume drift checks (`.pipeline/design-v2.md:258-335`).
- Does it fully resolve the concern? No. The design upgrades path-only pointers into path-plus-hash claims, but for artifacts outside the phase directory it still does not preserve the historical content. If a referenced repo file changes, the system can detect drift, but it cannot reconstruct the original evidence unless the spec later adds a copied immutable artifact or a git object identity. That means auditability becomes "detectably broken" instead of "durably preserved."
- Does it introduce new problems? Yes. A completed phase can now become non-replayable if an external referenced file changes, and the design gives no recovery path beyond stopping automatic resume and asking humans to investigate.
- Grade: `PARTIALLY_RESOLVED`

### 4. Execute as nested workflow
- Original concern: execute needed an explicit adapter boundary so the parent pipeline would not peek into relay internals such as `batch.json`.
- Was the fix applied in v2? Yes. v2 formalizes `execute` as a child workflow behind an adapter, defines `adapter-status.json` as the only public status surface, and explicitly states that the pipeline never reads `batch.json` directly (`.pipeline/design-v2.md:337-432`).
- Does it fully resolve the concern? Not fully. The parent no longer peeks into `batch.json`, but it now mirrors child status into both `phase.json.child_workflow` and `state.json.child_workflow` via `child_checkpoint` (`.pipeline/design-v2.md:455-478`). Without an authority matrix for crashes, detached child processes, and stale summaries, the nested workflow is acknowledged but not yet operationally closed.
- Does it introduce new problems? Yes. There are now three status surfaces for execute progress: `adapter-status.json`, `phase.json.child_workflow`, and `state.json.child_workflow`. v2 does not define which one wins after disagreement.
- Grade: `PARTIALLY_RESOLVED`

## 2. Remaining Weaknesses

### Still present from the original review

1. Critical: live-state authority is still undefined.
- v2 explicitly defers this (`.pipeline/design-v2.md:640-643`).
- The original critical concern still stands: while an execute child workflow is active, the design does not define whether the source of truth is the running adapter process, `adapter-status.json`, `phase.json`, `state.json`, or the event ledger.
- This is not a paperwork gap. It is the difference between safe resume and duplicate dispatch.

2. High: triage and align still do not have the same adapter-grade contract that execute now has.
- v2 explicitly defers a generic phase adapter registry (`.pipeline/design-v2.md:645-646`).
- That means the design is more modular for execute than for the rest of the phase engine.
- In practice, spec writers would still have to invent the compatibility boundary for non-execute phases.

3. High: the align-to-execute gate is still structurally stronger than semantically closed.
- v2 explicitly defers stronger semantic closure such as first-class `decisions[]`, `prohibited_alternatives[]`, examples, or contract tests (`.pipeline/design-v2.md:648-649`).
- The original failure mode still applies: two strong workers can still receive the same packet and produce materially different systems while the gate passes.

4. High: constraint supersession is still too coarse.
- v2 explicitly defers fine-grained supersession in favor of phase-level deltas (`.pipeline/design-v2.md:651-652`).
- That keeps active truth smeared across epochs and phase prose instead of addressable typed records.

5. Medium: fast-path classification is still underdesigned.
- v2 explicitly defers replacing the file-count heuristic with a risk classifier (`.pipeline/design-v2.md:654-655`).
- That means the design still has no principled answer to "small diff, high architectural risk."

6. Medium: crash-safe finalization is still underdesigned.
- v2 explicitly defers temp-directory promotion and incomplete-phase transaction semantics (`.pipeline/design-v2.md:657-658`).
- The original partial-write scenario still exists: the design describes what must exist at completion, but not how incomplete outputs are staged, promoted, or resumed safely.

### New or sharpened weaknesses introduced by v2

1. High: the root is still cwd-relative.
- This is the sharpest new contradiction in the doc.
- The design says roots should never be inferred from cwd, but every canonical example root remains `.pipeline` or `.pipeline/...` (`.pipeline/design-v2.md:96-120`, `.pipeline/design-v2.md:167-173`, `.pipeline/design-v2.md:391-408`, `.pipeline/design-v2.md:441-452`, `.pipeline/design-v2.md:531-544`).
- A spec written from this design would still have to decide whether roots are absolute, repo-root-relative, or process-cwd-relative.

2. High: rooted relay migration is still conceptual, not yet contractual.
- v2 correctly identifies that `update-batch.sh`, `compose-prompt.sh`, the manage-codex skill, and the relay templates all need rooting (`.pipeline/design-v2.md:480-544`).
- But it does not define how template placeholders are expanded, how legacy `.relay/...` outputs are rejected, or how mixed rooted/unrooted prompt artifacts fail closed.
- That is a real compatibility surface, not just documentation cleanup.

3. High: child status mirroring creates a fresh split-brain risk.
- `adapter-status.json` is adapter-owned.
- `phase.json.child_workflow` and `state.json.child_workflow` are parent-owned mirrors.
- v2 defines copying, but not reconciliation.
- As written, stale mirrored summaries can survive longer than the child runtime that produced them.

4. Medium: immutable evidence and runtime scratch are still not cleanly separated.
- The execute-phase example records `adapter-status.json` inside the `artifact_manifest` alongside historical outputs (`.pipeline/design-v2.md:204-235`).
- That mixes an operational runtime status file with durable phase evidence.
- The design should specify which runtime artifacts are historical record, which are ephemeral scratch, and which must never be locked.

## 3. Modularity and Flexibility

v2 is more modular than the original design in three important ways:

1. The namespace is now explicit.
- Root-first path derivation is the right abstraction for phase-local execution.
- It opens the door to multiple pipelines, relocation, and cleaner cleanup policies.

2. The state split is healthier.
- `state.json` is now an index.
- `phase.json` owns phase-local metadata.
- `events.ndjson` remains the audit trail.
- That is a much better decomposition than trying to make one file be both small and historically rich.

3. Execute is now a real subsystem boundary.
- The adapter contract is the best change in the revision.
- It lets the parent talk in pipeline concepts instead of relay-internal ones.

That said, the design is only locally modular, not yet globally modular:

1. Execute has a versioned adapter.
- Triage and align still mostly have skill-shaped contracts.
- So the phase engine is still unevenly abstracted.

2. The filesystem is still the main public contract.
- v2 improves the directory structure, but raw paths remain the primary boundary.
- Typed decisions, capabilities, or constraint records still do not exist.

3. v2 opens good future opportunities.
- A canonical root model would make multi-pipeline and resume behavior much cleaner.
- A generic phase adapter registry would turn the current execute-only win into a true engine-level abstraction.
- Per-phase manifests create a plausible future for cleanup, archival, and artifact GC.

## 4. Readiness Assessment

Recommendation: `NO-SHIP` for spec writing.

Why:
- The design is materially better, but it still leaves at least one original critical problem unresolved: live-state authority during active child execution.
- It also leaves spec authors to invent rules for cwd-independent roots, immutable external evidence, and crash-safe completion.
- Those are structural decisions, not implementation details.

What must change before this is spec-ready:

1. Add a live-state authority matrix.
- For each surface (`state.json`, `phase.json`, `events.ndjson`, `adapter-status.json`, `adapter-lock.json`, running child process), define:
- who writes it
- who reads it
- when it is authoritative
- how resume reconciles disagreement
- how duplicate dispatch is prevented after crash or detached child recovery

2. Make roots canonical and cwd-independent.
- Persist canonical absolute roots, or persist a canonical repo root plus root-relative paths.
- Validate after canonicalization, not raw string equality.
- State plainly whether rooted paths may ever be relative.

3. Finish immutable evidence for external artifacts.
- For artifacts outside the phase root, require either:
- a copied immutable artifact inside the phase tree, or
- a git commit/blob identity plus the path
- Hash-only drift detection is not enough if the goal is durable historical truth.

4. Specify crash-safe finalization and checkpoint semantics.
- Define staging vs committed artifacts.
- Define incomplete-phase statuses.
- Define how `phase_completed` becomes atomic.
- Define heartbeat/expiry rules for active child workflows and attach locks.

Strongly recommended immediately after the blockers:
- strengthen semantic closure for the align gate
- replace the fast-path file-count heuristic with a risk classifier

### Verification baseline

Current repo verification does not change the design verdict, but it is worth recording:

- `cargo fmt --all --check`: pass
- `cargo clippy -- -D warnings`: pass
- `cargo test`: pass
- `cargo test -p capacitor-core`: pass
- `cargo test -p capacitor-core --test delegation_contract`: pass
- `swift test --package-path apps/swift`: pass
- `./scripts/verify/verify.sh --layers 1,2`: pass
- `./scripts/verify/verify.sh --grade`: fail, `real`

The `--grade` failure is not a sandbox artifact. `.verifier/reports/layer3.json` reports grade `C` against a minimum `B`, driven by existing elegance debt in large Swift/Rust files and verifier scripts.

## 5. What's Strong

1. The thin-index move is absolutely the right call.
- This is the cleanest and most convincing fix in the revision.

2. The execute adapter boundary is directionally excellent.
- "The pipeline never reads `batch.json` directly" is exactly the kind of sentence this design needed.

3. Lock-on-complete plus hash verification is the right foundation.
- Even though it is not enough yet for external evidence, it is far better than path-only history.

4. The phase directory split is much healthier.
- `artifacts/`, `runtime/`, and `scratch/` is a cleaner mental model than one undifferentiated tree.

5. The document is honest about what remains unsolved.
- The deferred section is useful.
- It prevented this review from mistaking a partial improvement for closure.

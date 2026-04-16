# Batch 1: Path and Reference Corrections

## Charter
Lowest-risk fixes: broken paths, stale reference strings, and one PROVE-gated
prose edit inside a VERIFIER_CLAIM marker. Revert-all on verifier fail.

## Adjudication Corrections Applied Before Execute

| Queue Item | Action | Reason |
|---|---|---|
| B1.3 `checkpoint_bridge.rs` / `run_reducer.rs` path expansions | **DROPPED** | Cross-references worker hallucinated; `grep` in ADR-005 returned zero matches |
| B1.4 Stale line numbers (`reduce/mod.rs:177-221`, `lib.rs:888-956`, `App.swift:269-323`) | **DROPPED** | All three references are inside the `Current-State Snapshot (as of 2026-03-29)` frozen-history table (L20, L21, L23); brief.md boundary rule forbids edits |
| B1.2 Line 19 `runtime_projects.rs` | **NARROWED** to line 65 only | L19 is inside the frozen snapshot table; L65 is in "New Rust-side abstractions" table which is editable |

## Items

| # | File | Action | Evidence | Result |
|---|---|---|---|---|
| B1.1 | `AGENTS.md:37` | `runtime_setup.rs` → `runtime/setup/` | `ls core/capacitor-core/src/runtime/setup/` → mod.rs et al. | COMPLETE |
| B1.2 | `docs/architecture-decisions/005-*.md:65` | `runtime_projects.rs` → `runtime/projects.rs` | File exists at `core/capacitor-core/src/runtime/projects.rs` | COMPLETE |
| B1.5 | `docs/architecture-decisions/005-*.md:88` | `"4+ fragmented consumers"` → `"6 fragmented consumers (3 Rust: runtime_stats.rs, runtime/projects.rs, core_query.rs; 3 Swift: ProjectCreationCoordinator.swift, DelegationLoopManager.swift, SessionSummarizer.swift)"` | Line 126 of same doc has authoritative 6-count | COMPLETE |
| B1.6 | `docs/ARCHITECTURE.md:11` | `"authenticated local HTTP service"` → `"authenticated local runtime service"` (prose inside VERIFIER_CLAIM) | Verifier joins on `claim_id`; prose is editable | COMPLETE |
| B1.7 | `AGENTS.md:9` | `"Hook Server"` → `"Runtime Service"` | Matches ADR-004/005 canonical name; no branded external usage | COMPLETE |

## Verification

```
./scripts/verify/verify.sh --layers 1 --changed-only
```

- Exit code: 0
- `.verifier/reports/last-run.json`: `"status": "passed"`, `"violations": []`
- `VERIFIER_CLAIM(runtime_boundary_service)` still satisfied after prose rename (claim_id join)

Residual grep for stale tokens:
```
grep -rn "Hook Server\|runtime_setup\.rs" docs/ .claude/docs/ *.md  # → AGENTS.md clean
grep -rn "runtime_projects\.rs" docs/  # → only inside frozen L19 snapshot (intentional)
```

## Disposition: COMPLETE

Proceeding to Batch 2.

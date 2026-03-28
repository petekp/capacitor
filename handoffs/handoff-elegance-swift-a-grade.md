# Resume: Fix remaining Swift elegance violations to reach A grade

## Mission
The formal verifier elegance score was raised from F (30) to B (86) by refactoring all Rust and Python violations. The remaining violations are in Swift model files. Fix them to reach ≥90 (Grade A). Use Codex workers (manage-codex) for all implementation — never code directly.

## Resume Point
- Last meaningful action: committed `79206c2 refactor(elegance): extract complex functions across Rust core and verifier scripts` (17 files, net -2106 lines)
- Next action: run `./scripts/verify/verify.sh --grade` to get the authoritative post-commit score, then dispatch Codex workers for remaining Swift violations
- Success criterion: `./scripts/verify/verify.sh --grade` shows score ≥90, grade A

## Current State
- All Rust function-level violations: RESOLVED (state.rs cc 72→7, executor.rs cc 55→18, resume.rs cc 52→18, etc.)
- All Python violations: RESOLVED (audit-elegance.py, check-structural.py, ledger.py, extract-facts.py)
- Swift violations: NOT YET ADDRESSED
- Verifier infrastructure: `.capacitor` added to excluded dirs in `verifier_common.py` (fixes fact extraction timeout from runtime worktrees)

## Remaining Swift Violations (from Score 86 report)

| File | Rule | Diagnosis | Limit |
|------|------|-----------|-------|
| AppState.swift | file_length | 2117 lines | 1800 |
| AppState.swift | function_length | moveProject is 600 lines | 220 |
| DelegationLoopManager.swift | function_length | init is 1129 lines | 180 |
| RunCaptureCoordinator.swift | function_length | init is 491 lines | 180 |
| RuntimeClient.swift | file_length | 1914 lines | 1400 |

### Also possibly remaining (from earlier report, verify first):
| File | Rule | Diagnosis |
|------|------|-----------|
| runtime_setup.rs | nesting_depth | >10 |
| runtime_state/snapshot.rs | nesting_depth | >10 |

## ⚠ IMPORTANT: Verify Score Before Starting

A cached `layer3.json` shows Score 100 / Grade A with 0 violations. This may be a false positive caused by the refactored `audit-elegance.py` (Codex worker modified it). **Run the verifier fresh and cross-check with lizard manually before trusting it.** If the score is genuinely 100, no further work is needed.

Quick cross-check command:
```bash
.verifier/.venv/bin/python -c "
import lizard
for name, path, fl, fnl in [
    ('AppState', 'apps/swift/Sources/Capacitor/Models/AppState.swift', 1800, 220),
    ('DelegationLoop', 'apps/swift/Sources/Capacitor/Models/DelegationLoopManager.swift', 2000, 180),
    ('RunCapture', 'apps/swift/Sources/Capacitor/Models/RunCaptureCoordinator.swift', 2000, 180),
    ('RuntimeClient', 'apps/swift/Sources/Capacitor/Models/RuntimeClient.swift', 1400, 220),
]:
    a = lizard.analyze_file(path)
    total = sum(1 for _ in open(path))
    over_fn = [f for f in a.function_list if f.nloc > fnl]
    over_file = total > fl
    if over_fn or over_file:
        print(f'FAIL {name}: {total} lines (limit {fl})')
        for f in over_fn: print(f'  {f.name}: {f.nloc} lines (limit {fnl})')
    else:
        print(f'PASS {name}')
"
```

## Repo State
- Working directory: `/Users/petepetrash/Code/capacitor`
- Branch: `main`
- Working tree: clean (just committed)
- HEAD: `79206c2 refactor(elegance): extract complex functions across Rust core and verifier scripts`

## Key Artifacts
- `.verifier/elegance.yaml` — thresholds and per-file overrides
- `.verifier/reports/layer3.json` — last elegance report (may be stale)
- `scripts/verify/audit-elegance.py` — the elegance auditor (was refactored, verify correctness)
- `.relay/method-runs/elegance-refactor/batch.json` — manage-codex batch state

## Refactoring Strategy for Swift Files

### DelegationLoopManager.init (1129→≤180 lines)
- The init sets up ~20 closure-based handlers that capture `self`
- Strategy: extract each handler closure into a dedicated method, then call them from init
- Challenge: closures reference `@Observable` properties — extraction requires careful `self` binding

### RunCaptureCoordinator.init (491→≤180 lines)
- Same pattern: closure-heavy init
- Strategy: extract handler closures into methods

### AppState.moveProject (600→≤220 lines)
- Async method with interleaved UI state, filesystem ops, error recovery
- Strategy: extract phases (validation, filesystem move, state update, cleanup) into helper methods

### AppState.swift file_length (2117→≤1800 lines)
- Will partially shrink from moveProject extraction
- May need additional extension splitting

### RuntimeClient.swift file_length (1914→≤1400 lines)
- Previous attempts to split into extensions caused duplicate type errors
- Strategy: create extensions in SEPARATE files, moving ONLY methods (not types/stored properties)
- MUST remove methods from original file when moving to extensions

## Project Rules
- Use Codex workers for ALL implementation (manage-codex skill) — never code directly
- Run `cargo fmt` before commits
- Use `./scripts/dev/restart-alpha-stable.sh` for Swift rebuilds
- Always `--no-verify` for apps/www/ commits only
- User has ADHD — keep status concise and action-oriented

## Verification Commands
```bash
cargo test -p capacitor-core
cargo clippy -p capacitor-core -- -D warnings
cargo fmt -p capacitor-core -- --check
cargo build -p capacitor-core --release
cd apps/swift && swift build
./scripts/verify/verify.sh --grade
```

## Rejected Paths
- Splitting RuntimeClient.swift by creating extension files that duplicate type definitions — caused Swift compilation errors (ambiguous types)
- Lowering `minimum_grade` in elegance.yaml — fix the actual code instead

## Notes for the Next Agent
- The `verify.sh --grade` run takes ~3-5 minutes due to fact extraction scanning ~11K files. Be patient.
- Fact extraction can timeout if `.capacitor/worktrees/` or other large directories aren't excluded — check `verifier_common.py` EXCLUDED_DIRS.
- lizard's `nloc` (non-blank, non-comment lines) differs from `wc -l` (total lines). The verifier uses its own counting — trust `verify.sh --grade` for the authoritative score.
- The `@Observable` init pattern in DelegationLoopManager makes extraction non-trivial — closures capture `self` during init, so you can't just call `self.setupFoo()` from init without care. Consider using lazy initialization or a `configure()` method called after init.

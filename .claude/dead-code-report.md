# Dead Code Sweep Report

Date: 2026-03-08
Scope: full repo, focused on docs/scripts/source artifacts after the closed finish-line tranche

## Confirmed Dead

### Orphaned Files

- `docs/audit/00-analysis-plan.md`
- `docs/audit/01-system-context.md`
- `docs/audit/02-container-diagram.md`
- `docs/audit/03-core-components.md`
- `scripts/ci/test-agent-observe.sh`
- `scripts/utils/fetch-cc-docs.ts`
- `scripts/.DS_Store`
- `.claude/.DS_Store`

Evidence:

- zero inbound references from current docs, CI workflows, architecture governance, app source, or Rust source
- no active runtime/build/test role

## Intentional Manual Utilities

- `scripts/release/release.sh`
- `scripts/utils/apply-icon-mask.swift`

Evidence:

- `release.sh` is referenced from `.claude/docs/release-guide.md`
- `apply-icon-mask.swift` is referenced from `assets/README.md`

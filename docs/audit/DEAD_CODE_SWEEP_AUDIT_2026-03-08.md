# Dead Code Sweep Audit

Date: 2026-03-08
Status: closed through `DC-501`

This audit starts the post-finish-line pristine sweep. The migration is closed; this tranche is about confirmed orphaned artifacts and dead repo clutter.

## Scope

- Swift app source and supporting docs/scripts
- current docs and architecture control plane
- orphaned artifacts with zero inbound references

## Method

- Scanned `docs/audit`, `scripts`, `.claude`, `.github`, `architecture`, `apps/swift`, and `core` for inbound file-path references.
- Classified candidates with zero inbound references as confirmed dead only when they were not clearly intentional user-facing/manual utilities.
- Kept unreferenced but plausibly intentional manual utilities in a review-only bucket rather than deleting them speculatively.

## Confirmed Dead

### Orphaned Docs

- `docs/audit/00-analysis-plan.md`
- `docs/audit/01-system-context.md`
- `docs/audit/02-container-diagram.md`
- `docs/audit/03-core-components.md`

Why confirmed:

- zero inbound references from `docs`, `architecture`, `.github`, `scripts`, `apps/swift`, or `core`
- they are analysis scaffolds from the pre-convergence architectural audit, not current guidance

### Orphaned Filesystem Metadata

- `scripts/.DS_Store`
- `.claude/.DS_Store`

Why confirmed:

- Finder metadata only
- no runtime, CI, or documentation value

### Orphaned Test Harness Script

- `scripts/ci/test-agent-observe.sh`

Why confirmed:

- zero inbound references from docs, CI workflows, architecture governance, or source
- not called by any wrapper or workflow
- tests an internal diagnostic CLI but is not wired into any active verification surface

## Intentional Manual Utilities

- `scripts/release/release.sh`
- `scripts/utils/apply-icon-mask.swift`

Reason:

- `release.sh` is explicitly referenced from `.claude/docs/release-guide.md`
- `apply-icon-mask.swift` is explicitly referenced from `assets/README.md`

## Proposed Slices

### DC-500: Dead Code Sweep Audit

Outcome:

- record confirmed dead artifacts
- separate them from merely unreferenced manual utilities

### DC-501: Orphaned Artifact Deletion

Outcome:

- delete the confirmed-dead docs, metadata files, and unreferenced CI harness
- add denylist protection so they cannot return silently

Status: completed.

Closed state after DC-501:

- the four unlinked audit scaffolds are deleted
- the unreferenced `scripts/ci/test-agent-observe.sh` harness is deleted
- stray `.DS_Store` metadata files are deleted

### DC-502: Final Orphaned Utility Cleanup

Outcome:

- delete the unreferenced `fetch-cc-docs.ts` utility
- document the retained icon-generation utility so it is no longer orphaned

Status: completed.

Closed state after DC-502:

- `scripts/utils/fetch-cc-docs.ts` is deleted
- `scripts/utils/apply-icon-mask.swift` is retained as an intentional documented utility

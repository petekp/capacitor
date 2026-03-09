# Structure Modernization Audit

Date: 2026-03-08
Status: closed through `SM-602`

This audit starts the final structure-modernization tranche after the closed finish-line and dead-code sweeps.

## Mission

Remove migration-shaped namespace names from the live repo so the structure reflects the steady-state architecture rather than the refactor path that got us here.

## Measured Structure Debt

Measured on March 8, 2026.

| Pattern | Current count | Why it matters | Ratchet |
| --- | ---: | --- | --- |
| references to prior Rust migration namespace naming in live code paths | 0 | the live Rust code no longer advertises the old bounded-context namespace | frozen at `0` |
| references to prior repo-level governance namespace naming in active surfaces | 0 | active CI/docs/governance no longer speak in migration terms | frozen at `0` |
| empty Swift migration directory husks | 0 | the empty local `Models` directory shells are gone | frozen at `0` |

## Hard Conclusions

1. The live Rust namespace has been modernized from the old migration-era name to `contexts/`.
2. The repo-level governance surface now uses the permanent `architecture/` namespace.
3. Migration-shaped directory husks are gone from the Swift shell tree.

## Proposed Slices

### SM-600: Structure Modernization Audit
Status: completed.

### SM-601: Rust Context Namespace Rename

Outcome:

- adopt `core/capacitor-core/src/contexts` as the permanent bounded-context namespace
- rename the old shell/composition type to `ContextServices`
- update docs and guards to match

Status: completed.

### SM-602: Governance Surface Rename

Outcome:

- adopt `architecture/` as the permanent repo-level governance namespace
- retarget CI, docs, scripts, and local guidance

Status: completed.

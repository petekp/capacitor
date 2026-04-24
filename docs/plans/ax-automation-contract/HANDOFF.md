# Handoff — AX Automation Verification

## Mission

Keep AX regressions in the project-card/details surface detectable as an operational gate instead of relying on ad hoc manual relaunch attempts.

## Now True

- `scripts/ci/ax-automation-verify.sh` is the stable AX verifier entrypoint.
- Pre-merge runtime reliability now runs a one-pass AX smoke verification lane.
- Repeated AX smoke verification with log-health checks remains available as an explicit local/pre-release command.
- `[WindowAX]` lifecycle evidence is emitted from source-owned Swift logging instead of depending on an old local build artifact.

## Commands

- Fast lane:
  - `bash scripts/ci/ax-automation-verify.sh --runs 1 --skip-details`
- Strict lane:
  - `bash scripts/ci/ax-automation-verify.sh --runs 3 --require-log-health`
- Non-blocking trust probe:
  - `bash scripts/ci/ax-automation-verify.sh --runs 1 --allow-untrusted --skip-details`
- Full contract ship gate:
  - `bash docs/plans/ax-automation-contract/SHIP_CHECKLIST.md`

## Evidence Contract

- Fail on:
  - `No AX windows were found...`
  - runner/step timeout errors
  - missing `runner.complete` in an expected phase log
- Log health requires fresh `[WindowAX]` evidence for:
  - `applicationDidBecomeActive`
  - `didBecomeKey`
  - at least one fresh line with `isKey=true` and `isMain=true`
- Artifacts live under `artifacts/ax-automation-verification/<timestamp>/`

## Next Agent Notes

- Hosted CI may not have Accessibility trust; the verifier should label that as `skipped_untrusted` only when `--allow-untrusted` is set.
- The verifier seeds a repo-owned temporary `projects.json` if the user environment does not already have two pinned projects, so do not assume `~/.capacitor/projects.json` exists on CI.

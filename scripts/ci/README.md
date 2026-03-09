# CI Scripts

These scripts are the mechanical verification layer for Capacitor.

Use these entry points directly:

- `scripts/ci/runtime-reliability.sh ci`
  Pre-merge runtime reliability suite
- `scripts/ci/runtime-reliability.sh nightly <report-path>`
  Nightly runtime reliability plus soak benchmark
- `scripts/ci/session-state-gate.sh`
  Session-state blocking gate
- `scripts/ci/non-demo-ax-smoke.sh`
  AX/UI smoke checks against real project surfaces
- `scripts/ci/swiftformat-lint.sh`
  Swift formatting lint
- `scripts/ci/test-surface-audit.sh --check`
  Frozen test-surface anti-pattern audit

Notes for coding agents:

- These scripts should be deterministic and side-effect light.
- If a CI wrapper points at a deleted path, that is a bug even if grep returns zero.
- Prefer one canonical wrapper over duplicated inline workflow logic.

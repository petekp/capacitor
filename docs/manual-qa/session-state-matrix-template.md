# Session State Manual QA Report

- Date (UTC):
- Tester:
- Build/Commit:
- Environment: macOS version, terminal(s), tmux version
- Gate doc: `docs/SESSION_STATE_RELEASE_MATRIX.md`

## Run Markers

- Start marker:
- End marker:

Example marker commands:

```bash
printf "[MANUAL-TEST][START] session-state %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ~/.capacitor/daemon/app-debug.log
printf "[MANUAL-TEST][END] session-state %s\n" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> ~/.capacitor/daemon/app-debug.log
```

## Scenario Results

- SS-P0-1:
- SS-P0-2:
- SS-P1-1:
- SS-P1-2:
- SS-P1-3:
- SS-P2-1:
- SS-P2-2:

## Required Log Evidence (SS-P0)

- App debug log reference:
- Classification coverage summary present (`SS-P0-1`): yes/no
- Stop-gate origin/age checks present (`SS-P0-2`): yes/no

## Forbidden Signals Check

Run:

```bash
rg -n "silent drop|indefinite working|stale override|duplicate override" ~/.capacitor/daemon/app-debug.log
```

- Forbidden signals detected: yes/no
- If yes, line ranges and notes:

## Structured Fields Presence (C6)

Confirm logs contain:

- `gate_id`
- `scenario_id`
- `classification`
- `transition`
- `skip_reason`
- `event_id`
- `session_id`

## Triage Notes (for P1/P2 failures)

- Issue:
- Severity:
- Owner:
- Target fix date:
- Risk acceptance note link:

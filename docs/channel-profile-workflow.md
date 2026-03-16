# Channel + Profile Workflow

> Doc role: `task-runbook`
> Status: Task-specific workflow reference. This is not the current system architecture spec.

## Why this exists

Capacitor now separates:

- **Channel**: distribution audience (`alpha`, `beta`, `prod`, etc.)
- **Profile**: feature posture for local dev (`stable` or `frontier`)

For public alpha polishing, local dev/debug workflows should stay on **`alpha` channel** while still allowing a **frontier** posture for feature exploration.

## Runtime precedence

### Channel resolution

1. `CAPACITOR_CHANNEL` environment variable
2. `CapacitorChannel` in app `Info.plist`
3. `~/.capacitor/config.json` channel
4. Build default

### Profile resolution

1. `CAPACITOR_PROFILE` environment variable
2. `CapacitorProfile` in app `Info.plist`
3. Default: `stable`

## Profiles

| Profile | Intent | Default feature posture |
| --- | --- | --- |
| `stable` | Daily alpha polish and reliability | Alpha-safe defaults (gated features off) |
| `frontier` | Internal planning and feature exploration | All current feature flags on |

Environment feature overrides still apply last:

- `CAPACITOR_FEATURES_ENABLED`
- `CAPACITOR_FEATURES_DISABLED`

## Canonical commands

```bash
# DEFAULT for agents and day-to-day dev: force alpha+stable
./scripts/dev/restart-alpha-stable.sh

# Frontier work: alpha + frontier (only when explicitly requested)
./scripts/dev/restart-alpha-frontier.sh

# Preserve whichever context is currently active (use intentionally)
./scripts/dev/restart-current.sh
```

Advanced explicit launch:

```bash
./scripts/dev/restart-app.sh --channel alpha --profile stable
./scripts/dev/restart-app.sh --channel alpha --profile frontier
```

Current context is persisted at:

`~/.capacitor/runtime-context.env`

Because context is persisted, `./scripts/dev/restart-current.sh` can keep you in `frontier` after a prior frontier run. Agent default should therefore be `./scripts/dev/restart-alpha-stable.sh` unless frontier is explicitly requested.

## Alpha-only guardrails in dev/debug

Dev/debug startup blocks non-alpha channels by default.

If you intentionally need non-alpha for debugging:

```bash
CAPACITOR_ALLOW_NON_ALPHA=1 ./scripts/dev/restart-app.sh --channel prod --profile stable
```

The recommended day-to-day command remains:

```bash
./scripts/dev/restart-alpha-stable.sh
```

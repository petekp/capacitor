# Architecture Primer

> Doc role: `agent-entrypoint`
> Status: Current. Read this first for architecture orientation.

Capacitor's architecture hierarchy is intentionally strict:

1. `.claude/docs/architecture-primer.md`
2. `docs/ARCHITECTURE.md`
3. `docs/architecture-decisions/004-dedicated-local-runtime-service.md`
4. `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md`

Use `AGENT_CHANGELOG.md` only after the canonical read path when you need recent deltas or retired seams to avoid resurrecting.

## Top Invariants

- Rust owns ingest, reducer/query truth, persisted runtime facts, and route derivation.
- `hud-hook serve` owns the authenticated local runtime-service boundary for live reads and ingest writes.
- Swift owns projection, freshness guards, activation policy interpretation, request arbitration, and macOS side effects.
- Persisted artifacts under `~/.capacitor/runtime/` are durability and debugging aids, not the primary live app boundary.
- Do not create parallel runtime policy owners across Rust and Swift.

## Ownership Split

| Subsystem | Owns | Does Not Own |
| --- | --- | --- |
| `core/capacitor-core/` | ingest normalization, reducer/query truth, routing facts, persistence, replayable artifacts | macOS automation, UI projection, terminal side effects |
| `core/hud-hook/` | local authenticated runtime-service shell, Claude hook ingress, shell cwd forwarding, `/runtime/*` surface | domain policy, UI lifecycle, activation execution |
| `apps/swift/` | runtime supervision, projection/stabilization, activation policy, coordination, tmux execution, terminal drivers | reducer truth, canonical runtime facts, adapter ingress |

## If You Need X, Open Y

- Current system boundary or live ownership split: `docs/ARCHITECTURE.md`
- Why the dedicated runtime service exists: `docs/architecture-decisions/004-dedicated-local-runtime-service.md`
- Authority-based state detection, degraded-mode rules, and the signal authority matrix: `docs/architecture-decisions/005-authority-based-multi-signal-state-detection.md`
- Orchestration, checkpoints, and review surfaces: `docs/orchestrator/` (start with `checkpoint-bridge.md`)
- Orchestrator terminology and disambiguation: `docs/orchestrator/terminology.md`
- Recent migrations and retired seams to avoid reintroducing: `AGENT_CHANGELOG.md`
- Runtime debugging workflow: `.claude/docs/debugging-guide.md`
- Release mechanics: `.claude/docs/release-guide.md`
- Implementation hazards and local conventions: `.claude/docs/gotchas.md`
- Channel/profile workflow details: `docs/channel-profile-workflow.md`

## Do Not Treat These As The Current Architecture Spec

- `AGENT_CHANGELOG.md`
- `docs/audits/`
- `docs/plans/`
- `docs/manual-qa/`
- `docs/archive/` (all subdirectories — retired docs preserved for history)

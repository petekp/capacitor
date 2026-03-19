# Migration Charter

> Doc role: `authoritative-plan`
> Status: Active

## Mission

Build the project-level orchestrator on top of the validated delegation loop
without regressing the proven user loop or letting legacy `Workstreams` shape
the architecture.

## Scope

- Orchestrator planning and control-plane artifacts under `docs/plans/orchestrator-next-slices/`
- Runtime orchestration state under `core/capacitor-core/src`
- Swift runtime/bridge/presentation surfaces under `apps/swift/Sources/Capacitor`
- Rust and Swift regression suites covering orchestration behavior
- Ubiquitous language and migration guidance for the feature

## Critical Workflows

- One project has one active orchestrator conversation
- One captured idea can still become one real worker in one managed worktree
- A worker can still publish a milestone, pause, and resume after a decision
- Restart recovery preserves orchestration truth
- Two projects with the same display name remain isolated by durable identity

## External Surfaces

- `GET /runtime/snapshot`
- `POST /runtime/delegation/mutate`
- future orchestrator registration surface
- local Claude session metadata under `~/.claude/projects/`
- managed git worktrees under `.capacitor/worktrees/`
- project artifact storage under `~/.capacitor/projects/{encoded_project_path}/`
- `claude -p`
- `git worktree`

## Invariants

- The authenticated local runtime service remains the authoritative machine-readable boundary.
- Swift remains the owner of local side effects and presentation.
- Human-readable files remain durable artifacts, not the only control plane.
- Durable identity is path-based, not display-name-based.
- `Workstreams` remains legacy and is not extended as part of this work.
- Every implementation slice starts with explicit deletion targets and verification commands.

## Non-Goals

- Cross-project orchestration
- Cloud execution
- Replacing Claude Code's native subagents
- A visible dependency graph editor
- Keeping `Workstreams` alive as a supported parallel feature

## Guardrails

- Point future agents at `AGENT_EXECUTION_PLAYBOOK.md` first.
- Use the terms in `UBIQUITOUS_LANGUAGE.md` consistently.
- Prefer a failing test or verifier rule before implementation.
- Delete replaced paths in the same slice that replaces them.
- Ratchet budgets can only decrease.
- Do not preserve legacy `Workstreams` names as compatibility abstractions.

## Ship Gate

### Automated Checks

- `bash docs/plans/orchestrator-next-slices/guard.sh`
- `cargo test -p capacitor-core --test delegation_contract`
- `cargo test -p capacitor-core`
- `swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests|AppStateSessionObservationTests|AppConfigTests'`
- `swift test --package-path apps/swift`
- `swift build --package-path apps/swift`

### Manual Checks

- Reopen a project with an active orchestrator and verify reconnect without duplicate sessions.
- Submit a milestone decision and verify the same worker session resumes.
- Restart the app mid-flight and verify orchestration state reconstructs correctly.
- Verify project cards remain comprehensible with active orchestration state.

### Cleanliness Checks

- No new orchestrator code depends on `WorkstreamsManager` or `WorkstreamsPanel`.
- No obsolete compatibility shims or temporary bridge types remain.
- No stale docs describe file-authoritative orchestration or a living `Workstreams` future.

# Plans Directory

Implementation plans for Capacitor. Files are prefixed by status.

## Prefixes

| Prefix | Meaning |
|--------|---------|
| `ACTIVE-` | Ready for implementation |
| `DONE-` | Completed (compacted summaries for reference) |
| `DRAFT-` | Work in progress |
| `REFERENCE-` | Long-lived reference docs (only if still accurate) |

## Active Plans

| Plan | Summary |
|------|---------|
| _None currently_ | — |

## Done

| Plan | Summary |
|------|---------|
| `DONE-activity-based-project-tracking.md` | Monorepo support via file activity tracking. Attributes edits to project boundaries. |
| `DONE-capacitor-global-storage.md` | Storage migration from `~/.claude/` to `~/.capacitor/` namespace. |
| `DONE-heartbeat-health-monitoring.md` | Detects when hooks stop firing mid-session via heartbeat file. |
| `DONE-idea-capture-redesign.md` | Fast capture flow with LLM-powered "sensemaking" for idea expansion. |
| `DONE-multi-agent-cli-support.md` | Starship-style adapter pattern for Claude, Codex, Aider, Amp, etc. |
| `DONE-shell-integration-engineering.md` | Shell precmd hooks push CWD for ambient project awareness. |
| `DONE-shell-integration-prd.md` | Product requirements for shell integration. |
| `DONE-workstreams-lifecycle.md` | Managed worktree lifecycle shipped (create/list/open/destroy) with safety guardrails and integration tests. |
| `DONE-ui-tuning-panel-rework.md` | Consolidated debug panels into unified UITuningPanel with sidebar. |

## Reference Documents

| Document | Purpose |
|----------|---------|
| _None currently_ | Legacy reference plans were removed after the runtime rewrite to avoid stale guidance. |

## Notes

- DONE plans are compacted summaries (not full implementation specs)
- Git history preserves original detailed versions
- New plans should start as `DRAFT-` until ready for implementation

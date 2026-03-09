# Claude Hook Integration Audit

Date: 2026-03-09

## Scope

Analyze how Capacitor interfaces with Claude Code events and determine:

1. Whether we still support multiple ways of doing the same thing.
2. Whether mutating `~/.claude/settings.json` is still necessary now that Claude Code supports HTTP hooks.
3. Whether the `hud-hook` binary is still required.

## Findings Summary

- Critical: 0
- High: 2
- Medium: 4
- Low: 0

Top issues:

1. Managed hook installation assumes an HTTP-only event model that does not match the current Claude Code event/type matrix.
2. Setup validation can report "installed/connected" without validating that the chosen hook type is legal for each managed event.
3. `hud-hook` is still a live ingress adapter, not just legacy baggage, because it owns both the HTTP server and shell CWD CLI.
4. Legacy `hud-hook handle` support remains as migration baggage even though the live binary no longer exposes that subcommand.
5. `handle.rs` still duplicates part of the reducer's transition logic.

## External Contract Snapshot

Official Claude Code hooks docs on 2026-03-09:

1. HTTP hooks are a handler type, not a settings-free event stream.
2. HTTP hooks must still be configured through Claude settings.
3. Several events remain command-only, including:
   - `SessionStart`
   - `SessionEnd`
   - `Notification`
   - `PreCompact`
   - `SubagentStart`
   - `TeammateIdle`

Reference:

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)

## Core Findings

### 1. Managed install writes HTTP hooks for command-only events

Location:

- [runtime_setup.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs#L33)
- [runtime_setup.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs#L693)

Problem:

Capacitor currently installs `type: "http"` hooks for every event in its managed set, even though Claude documents a mixed event/type matrix.

Consequence:

Install behavior is broader than the documented external contract.

### 2. Health validation does not validate transport legality per event

Location:

- [runtime_setup.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs#L378)
- [lib.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/lib.rs#L836)

Problem:

Capacitor checks whether a managed hook exists, not whether the hook type is valid for that event.

Consequence:

The UI can report a healthy configuration even if some event/transport pairs are invalid.

### 3. The live Claude event path is HTTP-only, but legacy command-hook migration code remains

Location:

- [serve.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/serve.rs#L12)
- [main.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/main.rs#L42)
- [runtime_setup.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/runtime_setup.rs#L439)

Problem:

The current live Claude event path is:

`Claude hook -> POST /hook -> hud-hook serve -> capacitor-core`

But compatibility logic for the old `hud-hook handle` path is still present in install, cleanup, and guard code.

Consequence:

The repo still carries legacy baggage that can shape maintenance decisions even though it is no longer part of the live path.

### 4. `hud-hook` is still required by the current architecture

Location:

- [main.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/main.rs#L42)
- [cwd.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/cwd.rs#L66)
- [HookServerManager.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/HookServerManager.swift#L123)
- [ShellSetupInstructions.swift](/Users/petepetrash/Code/capacitor/apps/swift/Sources/Capacitor/Models/ShellSetupInstructions.swift#L28)

Problem:

The binary is not just historical hook glue. It currently owns:

1. the local HTTP ingress server
2. the shell `cwd` CLI path

Consequence:

Removing it without replacing both ingress surfaces would break runtime behavior.

### 5. `handle.rs` duplicates reducer logic

Location:

- [handle.rs](/Users/petepetrash/Code/capacitor/core/hud-hook/src/handle.rs#L147)
- [reduce/mod.rs](/Users/petepetrash/Code/capacitor/core/capacitor-core/src/reduce/mod.rs#L346)

Problem:

`handle.rs` still computes local transition labels before passing events into the canonical reducer.

Consequence:

Capacitor has two partially overlapping state machines, but only one is truly authoritative.

### 6. Docs and helper scripts reinforce stale mental models

Location:

- [docs/ARCHITECTURE.md](/Users/petepetrash/Code/capacitor/docs/ARCHITECTURE.md#L11)
- [scripts/sync-hooks.sh](/Users/petepetrash/Code/capacitor/scripts/sync-hooks.sh#L3)
- [scripts/utils/fetch-cc-docs.ts](/Users/petepetrash/Code/capacitor/scripts/utils/fetch-cc-docs.ts#L5)

Problem:

Several docs and helper scripts still describe the system in older command-hook terms.

Consequence:

Future migration work is more likely to inherit stale assumptions unless the external contract is turned into a checked, shared source of truth.

## Conclusions

### Do we support multiple live Claude ingest paths?

No.

The live Claude event path is HTTP-only.

The old command-hook path survives only as migration and cleanup baggage.

### Can we stop mutating `~/.claude/settings.json` and rely on HTTP alone?

No.

HTTP is still configured through Claude settings. It is not a settings-free integration surface.

### Do we still need the binary?

For the current architecture, yes.

Not because HTTP inherently requires a binary, but because the current system still uses the binary as:

1. the local HTTP ingress adapter
2. the shell cwd submitter target

## Recommended Fix Order

1. Encode the Claude event/type matrix in a shared contract artifact.
2. Drive install and health validation from that artifact.
3. Keep mixed transport if we want full event coverage.
4. Remove legacy command-hook baggage that is no longer part of the chosen architecture.
5. Collapse duplicated state-transition logic so reducer ownership is unambiguous.
6. Update docs and scripts to reflect the actual ingress architecture.

## Verification Performed

- `cargo test -p capacitor-core runtime_setup`
- `cargo test -p hud-hook`

Both test runs passed on 2026-03-09.

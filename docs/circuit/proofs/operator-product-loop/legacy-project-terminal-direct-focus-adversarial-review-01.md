# Legacy Project Terminal Direct Focus Adversarial Review 01

Date: 2026-05-26

## Scope

Reviewed the legacy project-terminal fallback patch, focused activation tests, full Swift results, and live `pete-2025` Debug-app trace.

## Findings

No medium, high, or critical findings.

Low: The exact live branch where a tmux client exists but remains untrusted was not reproduced. In the running app, creating a real tmux client gave the runtime service trusted route evidence, so the live check exercised the trusted-route branch instead. The untrusted fallback branch is still covered by focused coordinator tests.

Low: The temporary Ghostty tabs created for the live proof were not closed automatically. The temporary tmux client was detached, and no extra Claude process or new Capacitor build remained.

## Rechecked Requirements

- Fallback project activation now distinguishes generated tmux guesses from trusted runtime routes.
- A selected project-root Ghostty terminal is accepted before tmux launch when there is no trusted tmux route.
- Runtime route evidence still allows tmux switch/focus.
- The implementation preserves Work Batch routing boundaries.
- Full Swift verification passed after the patch.

## Verdict

Clean for this milestone. Keep the broader goal active because naturally agent-created checkpoint proof, unrelated Task live recheck, and broader real Ghostty/tmux/Claude matrices remain open.

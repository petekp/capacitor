# Ship Checklist

## Automated Release Gates

- [x] `bash docs/plans/terminal-host-adapters/guard.sh`
- [x] `bash docs/plans/terminal-routing-foundation/guard.sh`
- [x] `cd apps/swift && swift test --filter 'ITermTerminalDriverTests|TerminalAppTerminalDriverTests|TerminalLauncherTests|GhosttyTerminalDriverTests|AppState.*Tests|ProjectCreationCoordinatorTests'`
- [x] `cd apps/swift && swift test`
- [x] `cargo test -p capacitor-core`

## Residue Sweep

- [x] `ScriptedTerminalDriver` is absent from `apps/swift/Sources`, `apps/swift/Tests`, `.claude/docs`, and `docs/ARCHITECTURE.md`
- [x] No active source or docs still contain `Couldn’t activate Ghostty.`
- [x] No shared host-terminal runtime owner remains besides pure helper functions
- [x] Host-terminal logs use concrete driver labels

## Docs and Operational Surfaces

- [x] `.claude/docs/terminal-activation-ux-spec.md` describes iTerm and Terminal.app as separate host adapters
- [x] `docs/ARCHITECTURE.md` reflects the final ownership split
- [x] `docs/manual-qa/terminal-routing-closeout-2026-03-12.md` or a follow-up proof doc captures the refreshed host-terminal evidence
- [x] `docs/plans/terminal-host-adapters/HANDOFF.md` records the final closeout status

## Manual-Only Checks

- [x] One live iTerm existing-TTY activation proof captured
- [x] One live Terminal.app existing-TTY activation proof captured
- [x] One live iTerm no-client attach-or-create proof captured
- [x] One live Terminal.app no-client attach-or-create proof captured

## Ship Decision

- Ready to ship: `yes`
- Remaining blockers:
  - None
- Evidence summary:
  - Automated guard and test gates passed on 2026-03-13
  - Manual host-adapter proof refreshed on 2026-03-13 with `[ITermTerminalDriver]` and `[TerminalAppTerminalDriver]` log labels

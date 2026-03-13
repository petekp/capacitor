# Ghostty AppleScript Migration Charter

## Mission

Replace Capacitor's Ghostty Accessibility-based routing and Ghostty-specific keystroke launch heuristics with Ghostty's native AppleScript window/tab/terminal API, while preserving the existing tmux-centered activation UX.

## Invariants

- Latest-intent-wins request arbitration remains unchanged.
- The single-client tmux model remains unchanged.
- iTerm and Terminal.app behavior remains unchanged.
- Ghostty reuse still prefers existing surfaces before creating a new one.
- Ghostty-specific AX code, tests, and docs are deleted in the same migration.
- The focused activation test surface stays green throughout the migration.

## Non-goals

- Expanding terminal support beyond Ghostty, iTerm, and Terminal.app.
- Changing tmux session resolution semantics.
- Refactoring unrelated runtime or SwiftUI code.
- Adding backwards compatibility for Ghostty versions older than 1.3.

## Guardrails

- Delete replaced Ghostty AX code in the same change that lands the AppleScript path.
- Keep raw Ghostty AppleScript in one adapter boundary.
- Ratchet Ghostty AX and Ghostty keystroke launch patterns to zero.
- Update docs and QA checklists in the same session as the code migration.

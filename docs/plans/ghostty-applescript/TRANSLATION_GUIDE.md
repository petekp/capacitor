# Translation Guide

## Old -> New

| Old pattern | New pattern |
|---|---|
| `GhosttyAXReader.readWindows()` | `GhosttyAutomationClient.readSnapshot()` |
| `AXPress` on tab | `select tab (...)` |
| `AXRaise` on window | `activate window (...)` |
| Focus matched tab | Select tab if needed, then `focus terminal id ...` |
| `open -a Ghostty.app` + delayed keystroke | `new window` with `new surface configuration`, `initial working directory`, and `initial input` |
| Tab-title-only matching | cached terminal ID -> working directory -> terminal/tab/window name matching |

## Gotchas

- `focus terminal id "..."` is valid, but `focus terminal (first terminal whose id is "...")` is not.
- `select tab (first tab of targetWindow whose id is "...")` works; keep the direct object reference inside the command.
- `activate window (first window whose id is "...")` works as the window-level fallback.
- Standardize on `new window` for launch/resume; that is the cold-start primitive proven by the live matrix.
- Standardize on `initial input` for launch/resume to preserve the current shell-first feel without extra keep-alive handling.
- Do not build launch around post-create `input text`; it returned success without the expected side effect in live testing.
- Do not search the whole repo for denylist patterns from the guard script itself; restrict the search scope to code and current docs.

## Before / After Examples

### Ghostty reuse

- Before: read AX windows -> fuzzy title match -> `AXPress` or `AXRaise`
- After: read Ghostty snapshot -> cached terminal ID or metadata match -> `select tab` and `focus`

### Ghostty launch

- Before: `open -a Ghostty.app` then `System Events` keystroke
- After this migration: `new window` with a `new surface configuration` that sets `initial working directory` and `initial input`

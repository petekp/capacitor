# Decisions

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## 2026-03-10 — D1 Adapter Boundary

Raw Ghostty AppleScript strings and parsing live in `GhosttyAutomationClient.swift`, not in `TerminalLauncher.swift`. This isolates the preview upstream API behind one boundary.

## 2026-03-10 — D2 No Ghostty AX Compatibility Path

Ghostty 1.3+ with AppleScript enabled is the supported baseline. The migration deletes Ghostty-specific AX routing instead of carrying a compatibility fallback.

## 2026-03-10 — D3 Launch via `initial input` (Superseded by D5)

Ghostty surface creation uses `new surface configuration` with `initial working directory` and `initial input`, not the `command` field. This preserves the current “launch a shell, then run the command” semantics.

## 2026-03-10 — D4 Ratchet To Zero (Superseded by D6)

The migration closes with zero-budget guards for `GhosttyAXReader`, Ghostty AX tokens, `open -a Ghostty.app`, and Ghostty-specific `System Events` keystroke usage.

## 2026-03-10 — D5 Launch Path Reversal (Supersedes D3)

Live Ghostty 1.3.0 smoke testing showed that `new surface configuration` plus both `initial input` and `command` produced inert `👻` tabs/windows with no working directory and no executed command. Because the upstream surface-construction API is not reliable enough yet, Ghostty launch and resume flows stay on the proven `open -a Ghostty.app` path for now.

## 2026-03-10 — D6 Ratchet Scope Narrowed (Supersedes D4)

The permanent zero-budget guards apply to Ghostty AX code only. `open -a Ghostty.app` and Ghostty-specific `System Events` launch scripts remain temporarily allowed until Ghostty's native surface-construction API is production-ready.

## 2026-03-13 — D7 Native Launch via `initial input` (Supersedes D5)

The 2026-03-13 live matrix showed that Ghostty 1.3.0 `new window` surface creation reliably honors `initial working directory` and `initial input` for the tmux attach/resume flows Capacitor ships. Capacitor standardizes on `initial input`, not `command`, because it preserves the existing shell-first launch semantics without introducing `wait after command` policy.

## 2026-03-13 — D8 Ratchet Legacy Launch to Zero (Supersedes D6)

With native Ghostty launch shipped, the migration's zero-budget guards again apply to the old `open -a Ghostty.app` launch path and Ghostty-specific `System Events` keystroke scripts, alongside the Ghostty AX denylist.

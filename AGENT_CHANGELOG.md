# Agent Changelog

> This file helps coding agents understand project evolution, key decisions,
> and deprecated patterns. Updated: 2026-01-24

## Current State Summary

Capacitor is a native macOS SwiftUI app (Apple Silicon, macOS 14+) that acts as a sidecar dashboard for Claude Code. The architecture uses a Rust core (`hud-core`) with UniFFI bindings to Swift. State tracking relies on Claude Code hooks that write to `~/.capacitor/`, with shell integration providing ambient project awareness via precmd hooks.

## Stale Information Detected

None currently. Last audit: 2026-01-24.

## Timeline

### 2026-01-24 — Shell Integration Performance Optimization

**What changed:** Rewrote shell hook to use native macOS `libproc` APIs instead of subprocess calls for process tree walking.

**Why:** Target <15ms execution time for shell precmd hooks. Subprocess calls (`ps`, `pgrep`) were too slow.

**Agent impact:** The `hud-hook cwd` command is now the canonical way to track shell CWD. Shell history stored in `~/.capacitor/shell-history.jsonl` with 30-day retention.

**Commits:** `146f2b4`, `a02c54d`, `a1d371b`

---

### 2026-01-23 — Plan File Audit and Compaction

**What changed:** Archived completed plans with `DONE-` prefix, compacted to summaries. Removed stale documentation.

**Why:** Keep `.claude/plans/` focused on actionable implementation plans.

**Agent impact:** When looking for implementation history, check `DONE-*.md` files for context. Git history preserves original detailed versions.

**Commit:** `052cecb`

---

### 2026-01-21 — Binary-Only Hook Architecture

**What changed:** Removed bash wrapper script for hooks, now uses pure Rust binary at `~/.local/bin/hud-hook`.

**Why:** Eliminate shell parsing overhead, improve reliability, reduce dependencies.

**Agent impact:** Hooks are installed via `./scripts/sync-hooks.sh`. The hook binary handles all Claude Code events directly.

**Deprecated:** Wrapper scripts, bash-based hook handlers.

**Commits:** `13ef958`, `6321e4d`

---

### 2026-01-20 — Bash to Rust Hook Migration

**What changed:** Migrated hook handler from bash script to compiled Rust binary (`hud-hook`).

**Why:** Performance (bash was too slow), reliability, better error handling.

**Agent impact:** Hook logic lives in `core/hud-hook/src/`. The binary is installed to `~/.local/bin/hud-hook`.

**Commit:** `c94c56b`

---

### 2026-01-19 — V3 State Detection Architecture

**What changed:** Adopted new state detection that uses lock file existence as authoritative signal. Removed conflicting state overrides.

**Why:** Lock existence + live PID is more reliable than timestamp freshness. Handles tool-free text generation where no hook events fire.

**Agent impact:** When debugging state detection, check `~/.capacitor/sessions/` for lock files. Lock existence = session active.

**Deprecated:** Previous state detection approaches that relied on timestamp freshness.

**Commits:** `92305f5`, `6dfa930`

---

### 2026-01-17 — Agent SDK Integration Removed

**What changed:** Removed experimental Agent SDK integration.

**Why:** Discarded direction—Capacitor is a sidecar, not an AI agent host.

**Agent impact:** Do not attempt to add Agent SDK or similar integrations. The app observes Claude Code, doesn't run AI directly.

**Commit:** `1fd6464`

---

### 2026-01-16 — Storage Namespace Migration

**What changed:** Migrated from `~/.claude/` to `~/.capacitor/` namespace for Capacitor-owned state.

**Why:** Respect sidecar architecture—read from Claude's namespace, write to our own.

**Agent impact:** All Capacitor state files are in `~/.capacitor/`. Claude Code config remains in `~/.claude/`.

**Key paths:**
- `~/.capacitor/sessions.json` — Session state
- `~/.capacitor/sessions/` — Lock directory
- `~/.capacitor/shell-cwd.json` — Active shell sessions

**Commits:** `1d6c4ae`, `1edae7d`

---

### 2026-01-15 — Thinking State Removed

**What changed:** Removed deprecated "thinking" state from session tracking.

**Why:** Claude Code no longer uses extended thinking in a way that needs separate UI state.

**Agent impact:** Session states are: Idle, Active, Working, Compacting, Error. No "Thinking" state.

**Commit:** `500ae3f`

---

### 2026-01-14 — Caustic Underglow Feature Removed

**What changed:** Removed experimental visual effect (underglow/glow).

**Why:** Design decision—cleaner UI without the effect.

**Agent impact:** Do not add back underglow or similar effects. The app uses subtle visual styling.

**Commit:** `f3826d5`

---

### 2026-01-13 — Daemon Architecture Removed

**What changed:** Removed background daemon process architecture.

**Why:** Simplified to foreground app with file-based state.

**Agent impact:** The app runs as a standard macOS app, not a daemon. State persistence is file-based.

**Deprecated:** Any daemon/background service patterns.

**Commit:** `1884e78`

---

### 2026-01-12 — Artifacts Feature Removed

**What changed:** Removed Artifacts feature, replaced with floating header with progressive blur.

**Why:** Artifacts was over-scoped. Simpler floating header serves the use case.

**Agent impact:** Do not add "artifacts" or similar content management features. The app focuses on session state and project switching.

**Commit:** `84504b3`

---

### 2026-01-10 — Relay Experiment Removed

**What changed:** Removed relay/proxy experiment.

**Why:** Discarded direction.

**Agent impact:** The app communicates directly with Claude Code via filesystem, not through relays.

**Commit:** `9231c39`

---

### 2026-01-07 — Tauri Client Removed, SwiftUI Focus

**What changed:** Removed Tauri/web client, focused entirely on native macOS SwiftUI app.

**Why:** Native performance, ProMotion 120Hz support, better macOS integration.

**Agent impact:** This is a SwiftUI-only project. No web technologies, no Tauri, no Electron.

**Commit:** `2b938e9`

---

### 2026-01-06 — Project Created

**What changed:** Initial commit, Rust + Swift architecture established.

**Why:** Build a native macOS dashboard for Claude Code power users.

**Agent impact:** Core architecture: Rust business logic + UniFFI + Swift UI.

---

## Deprecated Patterns

| Don't | Do Instead | Deprecated Since |
|-------|------------|------------------|
| Write to `~/.claude/` | Write to `~/.capacitor/` | 2026-01-16 |
| Use bash for hook handling | Use Rust `hud-hook` binary | 2026-01-20 |
| Use wrapper scripts for hooks | Use binary-only architecture | 2026-01-21 |
| Track "Thinking" state | Use: Idle, Active, Working, Compacting, Error | 2026-01-15 |
| Add daemon/background service | Use foreground app with file-based state | 2026-01-13 |
| Use Tauri or web technologies | Use SwiftUI only | 2026-01-07 |
| Run AI directly in app | Call Claude Code CLI instead | 2026-01-17 |
| Check timestamp freshness for session liveness | Check lock file existence + PID validity | 2026-01-19 |
| Use `Bundle.module` directly | Use `ResourceBundle.url(forResource:)` | 2026-01-23 |

## Trajectory

The project is moving toward:

1. **Multi-agent CLI support** — Starship-style adapters for Claude, Codex, Aider, Amp (plan completed)
2. **Enhanced shell integration** — Ambient project awareness via precmd hooks (just completed)
3. **Idea capture with LLM sensemaking** — Fast capture flow with AI-powered expansion (plan completed)

The core sidecar architecture is stable. Focus is on refinement, not architectural changes.

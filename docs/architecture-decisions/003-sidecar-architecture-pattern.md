# ADR-003: Sidecar Architecture Pattern

**Status:** Accepted
**Date:** 2026-01-14
**Deciders:** Core team
**Context:** Design of new features (especially Idea Capture) and overall product direction

---

## Context

Claude HUD started as a dashboard for observing Claude Code sessions. As we add new features (idea capture, project creation, AI-powered triage), we face a fundamental architectural choice:

**Should HUD be a standalone application with its own API integration, or a sidecar that leverages the user's existing Claude Code installation?**

This decision affects:
- How we handle authentication (API keys)
- Where AI inference happens (direct API vs Claude CLI)
- How we store data (our own files vs Claude Code's `~/.claude/` structure)
- Whether features work when Claude Code isn't installed
- User trust and transparency

---

## Decision

**Claude HUD is a sidecar that powers up your existing Claude Code workflow—not a standalone application.**

### Core Principles

1. **Leverage, Don't Duplicate**
   - Use the user's Claude Code installation as the foundation
   - Read from `~/.claude/` where Claude Code stores config, sessions, stats
   - Invoke `claude` CLI for AI features rather than calling Anthropic API directly
   - Respect existing terminal-based workflows

2. **Observe, Don't Replace**
   - HUD shows what Claude is doing, doesn't try to be Claude
   - Interactive work happens in terminals (CLI), not embedded in HUD (SDK)
   - State tracking via hooks (HUD reads files Claude writes)
   - No attempt to "hijack" or join active CLI sessions

3. **Unified User Experience**
   - One API key (theirs, in `~/.claude/settings.json`)
   - One token usage pool (no surprise dual billing)
   - One conversation history (seamless handoffs CLI ↔ SDK)
   - One source of truth for project context

### In Practice

✅ **Do:**
- Read session files from `~/.claude/projects/`
- Parse `~/.claude/settings.json` for config
- Launch terminals with `claude` command
- Use hooks to write state files HUD reads
- Invoke CLI for AI features (triage, summaries, etc.)
- Store HUD-specific state in `~/.claude/hud-*.json` files

❌ **Don't:**
- Maintain separate API keys or authentication
- Call Anthropic API directly (bypass Claude Code)
- Duplicate Claude Code's project context logic
- Require users to configure HUD separately from Claude Code
- Try to run Claude "inside" the HUD app
- Build features that require Claude Code to not be installed

---

## Consequences

### Positive

1. **Simplicity** — Far less code. Reusing Claude Code infrastructure means we don't implement:
   - HTTP client for Anthropic API
   - Authentication and API key management
   - Project context gathering (file tree, git history, CLAUDE.md)
   - Prompt caching and token optimization
   - Conversation history management

2. **Reliability** — We depend on battle-tested infrastructure (Claude Code) rather than maintaining our own API integration.

3. **User Trust** — Transparent about what we're doing:
   - Users can inspect the files we read/write
   - Users control the `claude` CLI we invoke
   - No hidden API calls with their credentials

4. **Full Context** — Claude CLI already has complete project context. When we invoke it for triage or summaries, it has access to CLAUDE.md, file tree, git history, conversation history—without us having to pass that explicitly.

5. **Unified Billing** — All Claude usage shows up in one place (user's Claude Code account), not split across "HUD API calls" and "CLI API calls."

6. **Future-Proof** — As Claude Code gains features (better context, new tools, improved prompts), HUD automatically benefits without code changes.

### Negative

1. **Dependency** — HUD requires Claude Code to be installed. Can't ship to users who don't have it.
   - **Mitigation:** Our target audience already uses Claude Code. This is a dashboard for power users, not a general tool.

2. **CLI Performance** — Invoking CLI has more overhead (~200-500ms startup) than direct API calls.
   - **Mitigation:** For quick operations, cache results. For background processing, latency doesn't matter.

3. **Limited to CLI Capabilities** — We can't use features Anthropic API has but Claude CLI doesn't expose.
   - **Mitigation:** Claude Code is Anthropic's reference implementation. Missing features suggest they're not production-ready.

4. **Indirect Control** — We can't customize prompt templates, retry logic, or error handling as deeply as direct API integration would allow.
   - **Mitigation:** Claude Code's defaults are excellent. If we need customization, contribute to Claude Code upstream.

---

## Alternatives Considered

### Alternative 1: Standalone App with Direct API Integration

**Approach:** Build HUD as a fully independent app that calls Anthropic API directly, manages its own authentication, and maintains separate config/state.

**Pros:**
- No dependency on Claude Code
- Full control over API calls, prompts, error handling
- Slightly lower latency for AI operations

**Cons:**
- Massive code duplication (auth, context gathering, prompt engineering)
- User confusion (two API keys? two billing sources?)
- Can't leverage Claude's conversation history or cached context
- Have to reimplement features Claude Code already has

**Rejected because:** Violates "don't duplicate" principle. The marginal control isn't worth the complexity.

---

### Alternative 2: Hybrid (Direct API + CLI Fallback)

**Approach:** Use direct API for quick operations (triage, etc.), fall back to CLI for complex features (session resumption, full project context).

**Pros:**
- Lower latency for simple operations
- Still leverage CLI for heavy lifting

**Cons:**
- Split billing (user pays for API calls from two sources)
- Complex to explain ("some features use your API key, others use CLI")
- Have to maintain API client code anyway
- Risk of divergent behavior (API vs CLI give different results)

**Rejected because:** Complexity outweighs benefits. Users would be confused about what uses what.

---

## Implementation Notes

### For New Features

When designing a new feature, ask:

1. **Can Claude Code already do this?**
   - Yes → Leverage it (read files, invoke CLI)
   - No → Could this feature belong in Claude Code itself? (Consider upstreaming)

2. **Where should this data live?**
   - If Claude Code cares about it → `~/.claude/` in a format Claude can read
   - If HUD-only → `~/.claude/hud-*.json` with clear naming

3. **How should AI be involved?**
   - Invoke `claude` CLI with a well-crafted prompt
   - Parse structured output (JSON, markdown with frontmatter)
   - Don't build your own API integration

### For Existing Features

Review current features against sidecar principles:

- ✅ **Project stats** — Read from `~/.claude/projects/` (aligned)
- ✅ **Session state** — Hooks write to `~/.claude/hud-session-states-v2.json` (aligned)
- ✅ **Project creation** — Launches terminal with `claude` (aligned)
- ⚠️ **Summaries** — Currently uses subprocess to call CLI, could be more elegant (improve)
- ❌ **Idea capture (proposed)** — Original spec called Anthropic API directly (needs revision)

---

## References

- CLAUDE.md § Core Architectural Principle
- `.claude/docs/agent-sdk-migration-guide.md` — Documents CLI/SDK coexistence
- ADR-001 — State tracking via hooks (aligned with sidecar principle)

---

## Revision History

- 2026-01-14: Initial decision documented after design review of Idea Capture feature revealed misalignment

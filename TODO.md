# TODO

## Goals

- Eliminate cognitive overhead of context-switching between projects
- Surface project context automatically (no manual tracking)
- Enable instant resume: see status at a glance → pick project → jump in with full context
- Optimize users' Claude Code experience by closing the gap between novice and expert setups

---

## 🎯 Active

*Currently in progress. Limit to 1-3 items.*

### Dock Mode Polish Sprint (Round 2)
- [ ] Move status text underneath the title; hide dev server port
- [ ] Bump up the status text font size
- [ ] Tighten letter tracking on the title
- [ ] Summary text becomes vivid on update, then settles back
- [ ] Allow up to 3 lines of text for the summary
- [ ] Make cards 25% wider

---

## 📋 Next

*Researched, scoped, ready to start.*

### Agent SDK - Phase 2: Session Management
- [ ] Add `sessionId` field to Project/ProjectSession data model
- [ ] Capture session IDs from SDK init messages
- [ ] Store sessions in `~/.capacitor/sessions.json`
- [ ] Add "Resume Last Session" button in ProjectDetailView
- [ ] Implement session resumption via `resume: sessionId`

### Agent SDK - Phase 3: Embedded Agent Panel
- [ ] Design activity panel UI component (Swift)
- [ ] Implement real-time message streaming from SDK
- [ ] Add "Work On This" button to launch agents from HUD
- [ ] Display tool calls, thinking, and results in activity panel
- [ ] Handle permission prompts in HUD UI

---

## 💡 Backlog

*Ideas and lower priority items.*

### UX Enhancements
- [ ] Enable drag-and-drop on In Progress project cards for manual sorting; persist sort order so paused→revived projects remember their position
- [ ] Alternative views: Kanban, Agenda, Focus Mode

### Agent SDK - Phase 4: Quick Actions
- [ ] Define HUD agent presets (project-status, quick-fix, update-deps)
- [ ] Add quick action dropdown/buttons to Project Detail view
- [ ] Implement agent invocation with predefined agents

### Agent SDK - Phase 5: "Idea → V1" Launcher ⭐
**Spec:** `.claude/docs/feature-idea-to-v1-launcher.md`

Flagship feature: go from project idea to working v1 with minimal friction.
- 5a: Core Infrastructure
- 5b: Progress Tracking
- 5c: HUD Integration
- 5d: Polish & Edge Cases

### Agent SDK - Phase 6: Advanced Features
- [ ] Activity timeline with hook-based logging
- [ ] Session forking ("try different approach" button)
- [ ] Idea queue (batch multiple ideas, run overnight)

---

## 📚 Specs & Reference

| Document | Description |
|----------|-------------|
| `.claude/docs/agent-sdk-migration-guide.md` | Full SDK migration analysis and phases |
| `.claude/docs/feature-idea-to-v1-launcher.md` | TDD spec for Idea → V1 feature |
| `.claude/docs/status-sync-architecture.md` | Real-time status sync architecture |

---

## ⚠️ Not Recommended

### State Tracking Migration to SDK
Analysis complete: SDK hooks cannot replace shell hooks for CLI sessions (SDK isn't running during CLI usage). The current shell-based system (~246 lines of bash) works reliably. See `.claude/docs/agent-sdk-migration-guide.md` § "State Tracking Migration: Why Not to Do It".

---

*Completed work archived in `DONE.md`*

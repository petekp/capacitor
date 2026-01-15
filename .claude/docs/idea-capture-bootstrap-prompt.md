# Idea Capture Implementation - Bootstrap Prompt

**Copy this prompt into your next Claude session to begin Phase 1A implementation.**

---

I'm ready to implement the **Idea Capture** feature for Claude HUD. This feature enables instant capture of ideas (< 1 second) that are stored in markdown files Claude sessions can naturally read and update.

## Context

**Project:** Claude HUD - macOS dashboard for Claude Code (Rust core + Swift UI)

**Feature:** Idea Capture - upstream of project creation, solving "idea friction"

**Architecture:** Sidecar pattern - leverage existing Claude Code CLI, don't build standalone API integration

## Key Design Decisions (Already Finalized)

1. **Storage:** Per-project `.claude/ideas.local.md` (markdown, gitignored) + `~/.claude/hud/inbox-ideas.md` (unassociated ideas)
2. **IDs:** ULID (26-char base32, sortable) in format `[#idea-{ULID}]`
3. **Capture flow:** Save FIRST (< 1 second), validate SECOND (async, optional)
4. **AI integration:** Invoke `claude --print --output-format json` with stdin piping (NOT direct API)
5. **Workflow:** Terminal-based - "Work On This" launches `claude` with idea context

## Implementation Specs (Read These First)

**Must read before coding:**
1. `.claude/docs/idea-capture-file-format-spec.md` (475 lines)
   - Exact markdown format, parsing anchors, mutation rules
   - ULID format, metadata structure, delimiter rules
   - Reference parser pseudocode

2. `.claude/docs/idea-capture-cli-integration-spec.md` (787 lines)
   - CLI invocation patterns, JSON schemas
   - Swift examples, error handling
   - Hook integration (Phase 3)

3. `.claude/docs/feature-idea-capture.md` (883 lines)
   - High-level vision, UX design, phasing
   - Updated with sidecar architecture

**Architecture context:**
- `docs/architecture-decisions/003-sidecar-architecture-pattern.md` - Why sidecar, not standalone
- `CLAUDE.md` § Core Architectural Principle - Sidecar philosophy

## Phase 1A: Capture MVP (2-3 hours)

**Goal:** Instant text capture → markdown file → HUD display. No AI yet.

**Tasks:**
1. Create `core/hud-core/src/ideas.rs`:
   - ULID generation (use `ulid` crate)
   - Markdown parser with regex anchors: `[#idea-{ULID}]`, `- **Key:** value`, `---`
   - `capture_idea(project_path, idea_text)` - append to `## 🟣 Untriaged`
   - `load_ideas(project_path)` - parse markdown, return Vec<Idea>
   - `update_idea_status(project_path, idea_id, new_status)` - find & update Status: field

2. Update `core/hud-core/src/types.rs`:
   - Add Idea struct with UniFFI annotations
   - Fields: id (String/ULID), created_at, title, description, effort, status, triage, related

3. Update `core/hud-core/src/engine.rs`:
   - Add methods: `capture_idea()`, `load_ideas()`, `update_idea_status()`
   - Export via UniFFI

4. Regenerate Swift bindings:
   ```bash
   cargo build -p hud-core --release
   cd core/hud-core
   cargo run --bin uniffi-bindgen generate \
     --library ../../target/release/libhud_core.dylib \
     --language swift \
     --out-dir ../../apps/swift/bindings/
   ```

5. Create Swift UI:
   - `apps/swift/Sources/ClaudeHUD/Views/IdeaCapture/TextCaptureView.swift` - Modal text input
   - `apps/swift/Sources/ClaudeHUD/Views/Ideas/IdeaCardView.swift` - Compact card (60px height)
   - Update `apps/swift/Sources/ClaudeHUD/Models/AppState.swift` - Add `@Published var ideas: [String: [Idea]]`
   - Update `apps/swift/Sources/ClaudeHUD/Views/Projects/ProjectsView.swift` - Show ideas inline

6. Add file watcher:
   - Use `FSEventStreamCreate` or similar to watch `.claude/ideas.local.md`
   - Reload ideas when file changes (Claude edits from terminal)

## Critical Implementation Notes

**From file-format-spec.md:**
- Version marker MUST be first line: `<!-- hud-ideas-v1 -->`
- ULID format: 26 chars, uppercase, base32 (e.g., `01JQXYZ8K6TQFH2M5NWQR9SV7X`)
- Metadata parsing: `- **Key:** value` (order doesn't matter)
- Required metadata: Added, Effort, Status, Triage, Related
- Delimiter: `---` alone on line (3+ dashes)
- New ideas ALWAYS append to `## 🟣 Untriaged` section

**Rust dependencies to add:**
```toml
# core/hud-core/Cargo.toml
[dependencies]
ulid = "1.0"  # For ULID generation
regex = "1.0"  # Already in project
chrono = "0.4"  # For ISO8601 timestamps
```

**Example capture output:**
```markdown
### [#idea-01JQXYZ8K6TQFH2M5NWQR9SV7X] Add project search
- **Added:** 2026-01-15T10:23:42Z
- **Effort:** unknown
- **Status:** open
- **Triage:** pending
- **Related:** None

Add project search functionality to quickly find projects when list grows.

---
```

## Success Criteria for Phase 1A

- [ ] Click "Capture Idea" button in HUD
- [ ] Type idea text, press Enter
- [ ] Idea appears in `.claude/ideas.local.md` under `## 🟣 Untriaged`
- [ ] Idea card displays inline under project in HUD
- [ ] Edit markdown file manually → HUD updates (file watcher works)
- [ ] Total capture time: < 1 second from button click to display

## Next After Phase 1A

**Phase 1B:** Add "Work On This" button that launches terminal with idea context (1-2 hours)

---

**Ready to start?** Begin by reading the file format spec, then create `core/hud-core/src/ideas.rs` with the markdown parser.

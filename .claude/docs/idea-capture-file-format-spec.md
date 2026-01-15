# Idea Capture File Format Specification

**Version:** v1
**Status:** Implementation Contract
**Purpose:** Executable specification for `.claude/ideas.local.md` parsing and mutation

---

## File Locations

### Per-Project Ideas
```
{project-root}/.claude/ideas.local.md
```

**Storage semantics:**
- Personal to this user (gitignored via `.claude/*.local.md` pattern)
- One file per project
- HUD aggregates by scanning all projects' `.claude/` directories

### Inbox (Unassociated Ideas)
```
~/.claude/hud/inbox-ideas.md
```

**Storage semantics:**
- Global to this user
- Ideas without project association
- Namespace: `~/.claude/hud/` to avoid conflicts with other tools

---

## File Format

### Structure

```markdown
<!-- hud-ideas-v1 -->
# Ideas

## 🟣 Untriaged

### [#idea-01JQXYZ8K6TQFH2M5NWQR9SV7X] Fix authentication timeout
- **Added:** 2026-01-14T15:23:42Z
- **Effort:** small
- **Status:** open
- **Triage:** pending
- **Related:** None

Users reporting 401 errors after 30min idle.
Might be related to JWT expiration settings.

---

### [#idea-01JQXYZ9WKJHGFDSAQWERTYUIO] Add project search
- **Added:** 2026-01-14T16:45:12Z
- **Effort:** medium
- **Status:** open
- **Triage:** validated
- **Related:** None

Dashboard needs search to find projects quickly when list grows.
Should support fuzzy matching on project name and path.

---

## 🔴 P0 - Urgent

### [#idea-01JQXYZAPQMNBVCXZASDFGHJKL] Deploy hotfix
- **Added:** 2026-01-14T10:15:30Z
- **Effort:** small
- **Status:** in-progress
- **Triage:** validated
- **Related:** None

Production issue affecting all users.

---

## 🟠 P1 - Important

{ideas here}

## 🟢 P2 - Nice to Have

{ideas here}

## 🔵 P3 - Someday

{ideas here}
```

---

## Format Contract (Parsing Rules)

### 1. Version Marker (Line 1)
```markdown
<!-- hud-ideas-v1 -->
```

**Rules:**
- MUST be first line of file
- HUD checks this before parsing
- If missing or wrong version, HUD shows migration prompt

---

### 2. Idea Block Structure

Each idea is a heading (H3) followed by metadata and description:

```markdown
### [#idea-{ULID}] {Title}
- **Added:** {ISO8601-timestamp}
- **Effort:** {small|medium|large|xl}
- **Status:** {open|in-progress|done}
- **Triage:** {pending|validated}
- **Related:** {project-name or "None"}

{Description body - multiple lines allowed}

---
```

**Parsing anchors (HUD relies on these):**

1. **ID Token:** `[#idea-{ULID}]`
   - MUST appear in H3 line
   - ULID format: 26 chars, uppercase, base32-encoded (e.g., `01JQXYZ8K6TQFH2M5NWQR9SV7X`)
   - NEVER changes (stable identifier)

2. **Metadata Lines:** `- **Key:** value`
   - MUST start with `- **` and end with `** value`
   - Required keys: `Added`, `Effort`, `Status`, `Triage`, `Related`
   - Order doesn't matter (HUD parses by key, not position)
   - Values are case-insensitive for parsing

3. **Delimiter:** `---`
   - MUST be alone on line (3+ dashes, no leading/trailing content)
   - Separates idea blocks
   - Last idea in section doesn't require delimiter (section header or EOF ends it)

---

### 3. Priority Sections

```markdown
## 🟣 Untriaged
## 🔴 P0 - Urgent
## 🟠 P1 - Important
## 🟢 P2 - Nice to Have
## 🔵 P3 - Someday
```

**Parsing rules:**
- HUD extracts priority from **metadata only** (`Effort` field), not section location
- Sections are for human readability
- Claude may reorganize sections; HUD doesn't break

**Insertion rule:**
- New ideas ALWAYS append to `## 🟣 Untriaged` section
- Enrichment moves ideas to priority sections

---

## Mutation Contract (How Files Are Modified)

### HUD Mutations

**Capture (Append to Untriaged):**
```markdown
## 🟣 Untriaged

{existing ideas...}

### [#idea-01JQXYZ...] {User's idea text}
- **Added:** 2026-01-14T16:45:12Z
- **Effort:** unknown
- **Status:** open
- **Triage:** pending
- **Related:** None

{Raw captured text from user}

---
```

**Mark In Progress (When "Work On This" clicked):**
```diff
- **Status:** open
+ **Status:** in-progress
```

**Move Idea (Change project association):**
1. Extract entire idea block from source file (ID → delimiter)
2. Append to target file's `## 🟣 Untriaged` section
3. Remove block from source file
4. Update `Related:` field if cross-references needed

**Update After Enrichment:**
```diff
- **Effort:** unknown
+ **Effort:** medium
- **Triage:** pending
+ **Triage:** validated
```

Move from `## 🟣 Untriaged` to appropriate priority section.

---

### Claude Mutations

**Completing an Idea:**
```diff
- **Status:** in-progress
+ **Status:** done
```

**Adding Notes:**
Append text after metadata block, before delimiter:
```markdown
### [#idea-01JQXYZ...] Fix auth timeout
- **Added:** 2026-01-14T15:23:42Z
- **Effort:** small
- **Status:** in-progress
- **Triage:** validated
- **Related:** None

Users reporting 401 errors after 30min idle.

UPDATE 2026-01-15: Fixed by increasing JWT expiration from 30min to 2 hours.
Deployed to production. Monitoring for issues.

---
```

**Reorganizing Priorities:**
Claude may move ideas between sections. HUD doesn't care (uses metadata, not section).

---

## Preservation Rules (For Claude)

These instructions should be in project's `.claude/CLAUDE.md`:

```markdown
## Idea Capture Conventions

When editing `.claude/ideas.local.md`:

**Never modify:**
- ID tokens: `[#idea-...]` must stay exactly as-is
- Metadata line format: `- **Key:** value` structure

**To complete an idea:**
- Change `Status: open` → `Status: done`

**To add notes:**
- Append text after metadata block, before `---` delimiter

**Safe to change:**
- Idea titles (text after ID token)
- Description body text
- Priority sections (reorganize ideas as needed)
- Metadata values (except ID)
```

---

## Edge Cases & Error Handling

### Missing Metadata Keys
**If HUD encounters idea without required key:**
- Use safe default:
  - `Added`: Use file mtime
  - `Effort`: `unknown`
  - `Status`: `open`
  - `Triage`: `pending`
  - `Related`: `None`
- Log warning
- Continue parsing (don't fail entire file)

### Malformed ID
**If HUD encounters non-ULID format in `[#idea-...]`:**
- Skip idea (log error)
- OR: Attempt repair by generating new ULID (risky, only if user approves)

### Duplicate IDs
**If HUD finds same ID in multiple files:**
- First occurrence wins
- Log warning with file paths
- Mark duplicates as "conflict" in UI

### Empty File
**If file exists but is empty:**
- HUD initializes with:
```markdown
<!-- hud-ideas-v1 -->
# Ideas

## 🟣 Untriaged

{no ideas yet}
```

### File Doesn't Exist
**If `.claude/ideas.local.md` missing:**
- HUD creates it on first capture
- Initializes with version marker + structure

---

## Implementation Checklist

**Parser must:**
- [ ] Check version marker (line 1)
- [ ] Extract ideas using ID token as anchor (`[#idea-{ULID}]`)
- [ ] Parse metadata lines by key-value pattern
- [ ] Use `---` delimiter to separate ideas
- [ ] Handle missing metadata gracefully (defaults)
- [ ] Ignore section headings for data (metadata is source of truth)

**Writer must:**
- [ ] Generate valid ULIDs (26 chars, base32, sortable)
- [ ] Always append new ideas to `## 🟣 Untriaged`
- [ ] Preserve exact ID tokens when moving/updating
- [ ] Maintain metadata line format
- [ ] Add `---` delimiter after each idea (except last)

**File watcher must:**
- [ ] Detect changes to `.claude/ideas.local.md`
- [ ] Re-parse entire file (cheap, markdown is small)
- [ ] Update HUD display with new state
- [ ] Handle file deletion (treat as "no ideas")

---

## Testing Strategy

### Valid File Parsing
```bash
# Create test file with all variants
cat > test-ideas.md <<EOF
<!-- hud-ideas-v1 -->
# Ideas

## 🟣 Untriaged

### [#idea-01JQXYZ8K6TQFH2M5NWQR9SV7X] Test idea
- **Added:** 2026-01-14T15:23:42Z
- **Effort:** small
- **Status:** open
- **Triage:** pending
- **Related:** None

Description here.

---
EOF

# Parse with HUD, verify:
# - ID extracted: 01JQXYZ8K6TQFH2M5NWQR9SV7X
# - Added date: 2026-01-14T15:23:42Z
# - Effort: small
# - Status: open
```

### Malformed File Recovery
```bash
# Test missing delimiter
# Test missing metadata keys
# Test invalid ULID format
# Test empty file
# Test no version marker
```

### Mutation Correctness
```bash
# Append new idea → verify Untriaged section grows
# Mark in-progress → verify Status field updated
# Complete idea → verify Status: done
# Move idea → verify removed from source, added to target
```

---

## Migration from Future Versions

If format evolves (v2, v3), HUD must:
1. Detect version marker
2. Show migration prompt: "Ideas file needs upgrade. [Upgrade] [Cancel]"
3. Parse old format
4. Write new format with updated version marker
5. Preserve all data (IDs, content)

**Backward compatibility rule:** HUD v2 should still read v1 files gracefully (warn but parse).

---

## Reference Implementation (Pseudocode)

```swift
struct IdeaFile {
    let version: String
    var ideas: [Idea]
}

struct Idea {
    let id: String  // ULID
    var title: String
    var added: Date
    var effort: Effort
    var status: Status
    var triage: TriageStatus
    var related: String?
    var description: String
}

func parseIdeasFile(_ path: String) -> IdeaFile {
    let content = try String(contentsOf: path)
    let lines = content.split(separator: "\n")

    // Check version
    guard lines.first?.contains("hud-ideas-v1") else {
        throw ParseError.invalidVersion
    }

    var ideas: [Idea] = []
    var currentIdea: Idea?
    var descriptionLines: [String] = []

    for line in lines {
        if line.starts(with: "### [#idea-") {
            // Save previous idea
            if var idea = currentIdea {
                idea.description = descriptionLines.joined(separator: "\n")
                ideas.append(idea)
            }

            // Start new idea
            let id = extractID(from: line)  // [#idea-{ULID}]
            let title = extractTitle(from: line)
            currentIdea = Idea(id: id, title: title, ...)
            descriptionLines = []

        } else if line.starts(with: "- **") {
            // Parse metadata
            let (key, value) = parseMetadata(line)
            currentIdea?.setMetadata(key, value)

        } else if line.starts(with: "---") {
            // Delimiter - end current idea
            // (handled by next idea or EOF)

        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            // Description line
            descriptionLines.append(line)
        }
    }

    // Save last idea
    if var idea = currentIdea {
        idea.description = descriptionLines.joined(separator: "\n")
        ideas.append(idea)
    }

    return IdeaFile(version: "v1", ideas: ideas)
}
```

---

**End of File Format Specification**

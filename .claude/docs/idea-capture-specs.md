# Idea Capture Technical Specifications

**Version:** v1
**Purpose:** Implementation contracts for file format and CLI integration

---

## Quick Reference

### File Locations
- **Per-project:** `~/.capacitor/projects/{encoded-path}/ideas.md`
- **Order file:** `~/.capacitor/projects/{encoded-path}/ideas-order.json`

### ULID Format
26 chars, uppercase, base32 (e.g., `01JQXYZ8K6TQFH2M5NWQR9SV7X`)

### Metadata Fields
`Added` (ISO8601), `Effort` (small/medium/large/xl), `Status` (open/in-progress/done), `Triage` (pending/validated), `Related` (project name or None)

### CLI Pattern
```bash
{stdin} | claude --print --output-format json --json-schema '{...}' --tools "" --max-turns 1
```

---

# Part 1: File Format Specification

## File Structure

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

---

## 🔴 P0 - Urgent
## 🟠 P1 - Important
## 🟢 P2 - Nice to Have
## 🔵 P3 - Someday
```

## Parsing Anchors

HUD relies on these patterns:

| Anchor | Pattern | Notes |
|--------|---------|-------|
| Version | `<!-- hud-ideas-v1 -->` | Must be line 1 |
| ID Token | `[#idea-{ULID}]` | In H3 line, never changes |
| Metadata | `- **Key:** value` | Parse by key, not position |
| Delimiter | `---` | Alone on line (3+ dashes) |

## Mutation Rules

### HUD Mutations

**Capture (new idea):**
- Append to `## 🟣 Untriaged` section
- Set `Effort: unknown`, `Status: open`, `Triage: pending`

**Mark in-progress:** Change `Status: open` → `Status: in-progress`

**Update after enrichment:**
- Update `Effort` and `Triage: validated`
- Move to appropriate priority section

### Claude Mutations

**Complete idea:** Change `Status: in-progress` → `Status: done`

**Add notes:** Append text after metadata, before `---` delimiter

**Reorganize:** May move ideas between sections (HUD uses metadata, not location)

### Preservation Rules (for CLAUDE.md)

```markdown
## Idea Capture Conventions

When editing ideas files (`~/.capacitor/projects/{encoded-path}/ideas.md`):

**Never modify:**
- ID tokens: `[#idea-...]` must stay exactly as-is
- Metadata line format: `- **Key:** value` structure

**Safe to change:**
- Idea titles (text after ID token)
- Description body text
- Priority sections (reorganize as needed)
- Metadata values (except ID)
```

## Error Handling

| Scenario | Action |
|----------|--------|
| Missing metadata key | Use default, log warning, continue |
| Malformed ID | Skip idea, log error |
| Duplicate IDs | First wins, log warning, mark conflict in UI |
| Empty file | Initialize with version marker + structure |
| File missing | Create on first capture |

**Defaults:** Added=file mtime, Effort=unknown, Status=open, Triage=pending, Related=None

---

# Part 2: CLI Integration Specification

## Prerequisites

```bash
which claude          # Verify CLI available
claude --version      # Need v2.0+ for JSON output
```

**Auth:** Subscription (via `claude login`) or API key (`ANTHROPIC_API_KEY` env var)

## Core Pattern

```bash
cat <<EOF | claude --print \
  --output-format json \
  --json-schema '{schema}' \
  --tools "" \
  --max-turns 1
{input}
EOF
```

**Flags:**
- `--print` — Non-interactive, stdout output
- `--output-format json` — Structured output
- `--json-schema` — Validate against schema
- `--tools ""` — Disable all tools (security)
- `--max-turns 1` — Single inference (cost control)

## Use Case 1: Project Placement Validation

**When:** After capture, validate smart default project
**Cost:** ~100-200 tokens

### Schema
```json
{
  "type": "object",
  "properties": {
    "belongsHere": {"type": "boolean"},
    "suggestedProject": {"type": "string"},
    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    "reasoning": {"type": "string"}
  },
  "required": ["belongsHere", "confidence"]
}
```

### Input Template
```
Context: User is browsing project "${PROJECT_NAME}"

Active projects: project-a, project-b, project-c

Captured idea text: "${IDEA_TEXT}"

Question: Does this idea belong to project "${PROJECT_NAME}"?
If not, which active project is the best match?
```

## Use Case 2: Idea Enrichment

**When:** Background after session, or manual trigger
**Cost:** ~200-400 tokens

### Schema
```json
{
  "type": "object",
  "properties": {
    "priority": {"type": "string", "enum": ["p0", "p1", "p2", "p3"]},
    "effort": {"type": "string", "enum": ["small", "medium", "large", "xl"]},
    "tags": {"type": "array", "items": {"type": "string"}},
    "confidence": {"type": "number", "minimum": 0, "maximum": 1},
    "reasoning": {"type": "string"}
  },
  "required": ["priority", "effort", "confidence"]
}
```

### Input Template
```
Project: ${PROJECT_NAME}
Path: ${PROJECT_PATH}

Recent commits (last 3):
${RECENT_COMMITS}

Current idea to analyze:
### [#idea-${IDEA_ID}] ${IDEA_TITLE}
${IDEA_DESCRIPTION}

Assign priority (p0=urgent, p1=important, p2=nice, p3=someday),
effort (small=<2h, medium=2-8h, large=1-2d, xl=>2d), and tags.
```

## Error Handling

| Error | Response |
|-------|----------|
| CLI not found | Prompt: "Install Claude Code" |
| JSON output unsupported | Prompt: "Update to v2.0+" |
| Schema validation failed | Retry with fallback, or skip |
| Rate limit | Exponential backoff |
| Auth error | Show error, prompt to fix auth |
| Timeout (>30s) | Terminate, show error |

### Swift Types

```swift
enum CLIError: Error {
    case notFound
    case unsupportedVersion
    case validationError(String)
    case rateLimitError
    case authError(String)
    case timeout
}
```

## Hook Integration (SessionEnd)

**Location:** `~/.claude/scripts/hud-enrich-ideas.sh`

**Configuration:** In `~/.claude/settings.local.json`:
```json
{
  "hooks": {
    "SessionEnd": {
      "command": "~/.claude/scripts/hud-enrich-ideas.sh"
    }
  }
}
```

**Key points:**
- Prevent nested invocation with `HUD_HOOK_RUNNING` env var
- Check for pending ideas before invoking Claude
- Use `--settings <(echo '{"hooks":{}}')` to isolate hook invocation
- Log all activity to `~/.claude/hud-hook-debug.log`

## Performance

| Operation | Latency | Cost (approx) |
|-----------|---------|---------------|
| Validation | 1-2s | ~$0.0005/idea |
| Enrichment | 2-4s | ~$0.001/idea |
| Monthly (100 ideas) | — | ~$0.15 |

## Security

- Pass idea text via stdin (not command args)
- Validate project paths before use
- Schema validation enforced by CLI
- Additional validation in Swift
- Never execute Claude output as code
- Never log API keys
- Warn if using API key billing

## Debugging

Enable: `export HUD_CLI_DEBUG=1`
Log: `~/.claude/hud-cli-debug.log`

```bash
# Test CLI integration
echo '{"test":"value"}' | claude --print --output-format json \
  --json-schema '{"type":"object","properties":{"test":{"type":"string"}}}' \
  --tools "" --max-turns 1 <<< "Output the input JSON unchanged."
```

---

**End of Technical Specifications**

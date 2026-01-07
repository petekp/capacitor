# Claude Code Disk Artifacts Reference

Technical reference for all files and directories created by Claude Code CLI. This document helps assess what data is available for Claude HUD integration.

---

## Overview

**Primary Location:** `~/.claude/`
**Typical Size:** 500-700 MB (dominated by session history and debug logs)

### Size Distribution (Example)
| Directory | Size | Purpose |
|-----------|------|---------|
| `projects/` | 379 MB | Session history (JSONL files) |
| `debug/` | 128 MB | Debug logs and error traces |
| `file-history/` | 37 MB | File version backups |
| `plugins/` | 19 MB | Installed plugins cache |
| `shell-snapshots/` | 7 MB | Shell environment captures |
| `todos/` | 7 MB | Todo state snapshots |
| Config files | ~4 MB | Settings, caches, indexes |

---

## Configuration Files

### `~/.claude/settings.json`
**Format:** JSON
**Purpose:** Global Claude Code permissions and plugin configuration
**Created:** On first Claude Code run
**Updated:** When user changes settings or enables/disables plugins

```json
{
  "permissions": {
    "allow": ["WebSearch", "Edit", "Write", "Bash(...)"],
    "deny": [],
    "defaultMode": "acceptEdits"
  },
  "statusLine": { "type": "command", "command": "..." },
  "enabledPlugins": {
    "plugin-name@marketplace": true
  },
  "alwaysThinkingEnabled": true,
  "feedbackSurveyState": { "lastShownTime": 1234567890 }
}
```

### `~/.claude/settings.local.json`
**Format:** JSON
**Purpose:** User-specific local overrides (not synced)
**Note:** May contain sensitive configuration

### `~/.claude/CLAUDE.md`
**Format:** Markdown
**Purpose:** Global instructions (applies to all projects)
**Created:** Manually by user
**Location:** Also can exist per-project as `<project>/CLAUDE.md`

---

## Session History

### `~/.claude/projects/{encoded-path}/{session-id}.jsonl`
**Format:** JSONL (JSON Lines)
**Purpose:** Complete conversation history for each session
**Retention:** Permanent (never deleted)

**Path Encoding:** Directory path uses `/` → `-` substitution:
- `/Users/pete/Code/myapp` → `-Users-pete-Code-myapp`

**Session ID Formats:**
- UUID: `40b991e3-5517-4b62-912c-5e3aa9d938fe.jsonl` (regular sessions)
- Agent: `agent-a840201.jsonl` (multi-agent runs)

**Record Types in JSONL:**

1. **Summary Record**
```json
{
  "type": "summary",
  "summary": "Feature implementation and bug fixes",
  "leafUuid": "46d835b9-c7f6-4d3b-8f38-da4cb2868320"
}
```

2. **File History Snapshot**
```json
{
  "type": "file-history-snapshot",
  "messageId": "uuid",
  "snapshot": {
    "trackedFileBackups": {
      "src/App.tsx": {
        "backupFileName": "hash@v12",
        "version": 12,
        "backupTime": "2025-12-31T20:26:54.007Z"
      }
    }
  }
}
```

**Statistics Available (parsed from content):**
- Token counts: `input_tokens`, `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`
- Model usage: `claude-opus-4`, `claude-sonnet-4`, `claude-haiku` (count by model)
- Session metadata: summary text, timestamps

### `~/.claude/history.jsonl`
**Format:** JSONL
**Purpose:** Master command/action history across all sessions
**Size:** ~2.6 MB (continuously growing, never purged)

```json
{
  "display": "User's prompt or command",
  "pastedContents": {},
  "timestamp": 1761666217977,
  "project": "/Users/pete/Code/myapp"
}
```

---

## Statistics & Caching

### `~/.claude/stats-cache.json`
**Format:** JSON
**Purpose:** Global daily activity statistics
**Updated:** Daily

```json
{
  "version": 1,
  "lastComputedDate": "2026-01-05",
  "dailyActivity": [
    {
      "date": "2025-11-12",
      "messageCount": 987,
      "sessionCount": 8,
      "toolCallCount": 288
    }
  ]
}
```

### HUD-Specific Caches (created by Claude HUD)

| File | Purpose |
|------|---------|
| `hud.json` | Pinned projects list |
| `hud-stats-cache.json` | Token usage per project (mtime-based invalidation) |
| `hud-summaries.json` | Latest session summaries |
| `hud-project-summaries.json` | AI-generated project overview bullets |

---

## Plugin System

### `~/.claude/plugins/installed_plugins.json`
**Format:** JSON
**Purpose:** Installed plugins registry

```json
{
  "version": 2,
  "plugins": {
    "plugin-name@marketplace": [
      {
        "scope": "user",
        "installPath": "~/.claude/plugins/cache/marketplace/plugin-name/1.0.0",
        "version": "1.0.0",
        "installedAt": "2025-12-03T16:32:09.532Z",
        "gitCommitSha": "84d7b085...",
        "isLocal": true
      }
    ]
  }
}
```

### `~/.claude/plugins/cache/{marketplace}/{plugin}/{version}/`
**Contains:**
- `.claude-plugin/plugin.json` - Plugin metadata and configuration
- `.claude-plugin/marketplace.json` - Marketplace info
- `.lsp.json` - Language Server Protocol config (if applicable)
- `.mcp.json` - Model Context Protocol config (if applicable)
- Plugin source code and assets

### `~/.claude/plugins/local/`
**Purpose:** Local plugin development directory

---

## File Version Control

### `~/.claude/file-history/{session-uuid}/{hash}@v{version}`
**Format:** Original file format (preserved)
**Purpose:** Backup versions of files edited during sessions
**Retention:** Per-session (never cleaned up)

Files are referenced from session JSONL via `file-history-snapshot` records.

---

## Plans & Tasks

### `~/.claude/plans/{random-adjective-animal}.md`
**Format:** Markdown
**Purpose:** Task/plan documents created during development
**Naming:** e.g., `zesty-frolicking-yeti.md`, `moonlit-yawning-hare.md`

### `~/.claude/todos/{uuid}-agent-{uuid}.json`
**Format:** JSON
**Purpose:** Todo state snapshots during sessions

---

## Environment & Context

### `~/.claude/session-env/{session-uuid}/`
**Purpose:** Per-session environment state captures

### `~/.claude/shell-snapshots/snapshot-{shell}-{timestamp}-{hash}.sh`
**Format:** Shell script
**Purpose:** Shell configuration snapshots
**Pattern:** `snapshot-zsh-1756067216620-zbkgrc.sh`

---

## Debug & Diagnostics

### `~/.claude/debug/{session-uuid}.txt`
**Format:** Plain text
**Purpose:** Debug logs and error traces
**Note:** Can grow large (128 MB+), never automatically purged

---

## IDE & Extensions

### `~/.claude/ide/`
**Contains:** IDE-specific state, language server data, lock files

### `~/.claude/chrome/chrome-native-host`
**Purpose:** Chrome extension native messaging host

---

## Symlinked Directories

User-configurable symlinks for custom artifacts:
- `~/.claude/agents/` → Custom agents directory
- `~/.claude/commands/` → Custom commands directory
- `~/.claude/skills/` → Custom skills directory

---

## Data Retention Summary

| Category | Retention | Notes |
|----------|-----------|-------|
| Session JSONL | Permanent | Never deleted |
| `history.jsonl` | Permanent | Audit trail |
| Cache files | Mtime-based | Invalidated on source change |
| `file-history/` | Permanent | All versions kept |
| `debug/` | Permanent | Can accumulate significantly |
| `plans/` | Permanent | User-created documents |

---

## Key Patterns for HUD Integration

### Path Encoding
```
/Users/pete/Code/myapp → -Users-pete-Code-myapp
```

### Statistics Extraction
Token counts are embedded in JSONL session files. Parse with regex:
```regex
"input_tokens":(\d+)
"output_tokens":(\d+)
"cache_read_input_tokens":(\d+)
```

### Model Detection
```regex
"model":"(claude-[^"]+)"
```

### Mtime-Based Caching
Track file modification times to avoid re-parsing unchanged session files.

### Session Discovery
```
~/.claude/projects/{encoded-path}/*.jsonl
```

---

## What's NOT Available

- **Conversation content:** Full message text requires parsing complex JSONL structure
- **Tool call details:** Embedded in conversation, not extracted
- **Real-time session state:** No live updates (files written periodically)
- **Cross-session relationships:** Sessions are independent (no parent/child tracking)
- **User authentication:** No user identity stored locally

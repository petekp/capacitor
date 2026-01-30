# Capacitor Daemon IPC (v1)

This document describes the local IPC contract for `capacitor-daemon`. It is the source of truth for client integrations in hooks and the Swift app.

## Purpose

The daemon is the **single writer** for state. Clients send events and read state over a local Unix domain socket. This avoids multi-writer file races while keeping user workflows unchanged.

## Transport

- **Socket path:** `~/.capacitor/daemon.sock`
- **Encoding:** single JSON request per connection, optionally newline-terminated
- **Responses:** single JSON object, newline-terminated

## Request Format

```json
{
  "protocol_version": 1,
  "method": "get_health",
  "id": "req-123",
  "params": { }
}
```

### Fields
- `protocol_version` (required): must be `1`
- `method` (required): `get_health` or `event`
- `id` (optional): echoed back in responses
- `params` (optional): method-specific payload

## Response Format

```json
{
  "ok": true,
  "id": "req-123",
  "data": { ... }
}
```

On error:

```json
{
  "ok": false,
  "id": "req-123",
  "error": { "code": "invalid_params", "message": "event payload is required" }
}
```

## Methods

### `get_health`

Returns daemon metadata.

Response data:

```json
{
  "status": "ok",
  "pid": 12345,
  "version": "0.1.27",
  "protocol_version": 1
}
```

### `event`

Sends a single event to the daemon. The daemon validates the payload and responds with `{ "accepted": true }` when valid.

#### Event Envelope (v1)

```json
{
  "event_id": "evt-2026-01-30T12:00:00Z-1234",
  "recorded_at": "2026-01-30T12:00:00Z",
  "event_type": "session_start",
  "session_id": "abc-123",
  "pid": 1234,
  "cwd": "/Users/pete/Code/project",
  "tool": "Edit",
  "file_path": "/Users/pete/Code/project/file.rs",
  "parent_app": "tmux",
  "tty": "/dev/ttys003",
  "tmux_session": "dev",
  "tmux_client_tty": "/dev/ttys004",
  "notification_type": "idle_prompt",
  "stop_hook_active": false,
  "metadata": { "extra": "optional" }
}
```

#### Validation Rules

- `event_id` is required and must be ≤ 128 chars.
- `recorded_at` must be RFC3339.
- `event_type` must be one of:
  - `session_start`
  - `user_prompt_submit`
  - `pre_tool_use`
  - `post_tool_use`
  - `permission_request`
  - `pre_compact`
  - `notification`
  - `stop`
  - `session_end`
  - `shell_cwd`
- For session events (`session_*`, `pre_tool_use`, `post_tool_use`, `permission_request`, `pre_compact`, `notification`, `stop`): `session_id`, `pid`, and `cwd` are required.
- For `notification`: `notification_type` is required.
- For `stop`: `stop_hook_active` is required.
- For `shell_cwd`: `pid`, `cwd`, and `tty` are required.

## Error Codes (v1)

- `empty_request`
- `read_timeout`
- `read_error`
- `request_too_large`
- `invalid_json`
- `protocol_mismatch`
- `unknown_method`
- `invalid_params`
- `invalid_event_id`
- `invalid_timestamp`
- `invalid_pid`
- `missing_field`

## Notes

- One request per connection keeps clients simple and avoids partial framing bugs.
- The daemon enforces strict validation to prevent malformed events from corrupting state.
- If the daemon is unavailable, clients should fall back to legacy file writes (during migration).

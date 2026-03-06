# Subsystem Audit: Hook Ingress + Runtime Ingest

### [HOOK INGEST] Finding 1: Ambient `PWD` fallback can misattribute hook events

**Severity:** High  
**Type:** Bug  
**Location:** `core/hud-hook/src/hook_types.rs:179-185`, `core/hud-hook/src/handle.rs:73-106`

**Problem:**
When hook payloads omit `cwd`, `resolve_cwd` falls back to process-level `PWD`. In `serve` mode, `hud-hook` is a long-lived daemon, so `PWD` is the daemon launch directory, not the per-request Claude working directory. This can incorrectly route session state updates to the wrong project path instead of safely skipping.

**Evidence:**
`resolve_cwd` uses `self.cwd -> CLAUDE_PROJECT_DIR -> current_cwd -> PWD`, and the handler passes `current_cwd = None` for HTTP requests.

**Recommendation:**
For HTTP hook handling, remove `PWD` fallback (and optionally `CLAUDE_PROJECT_DIR` unless request-scoped). If `cwd` is absent, skip non-delete events deterministically.

### [HOOK SERVER] Finding 2: Request-size guard is bypassable when Content-Length is absent

**Severity:** Medium  
**Type:** Security  
**Location:** `core/hud-hook/src/serve.rs:65-80`

**Problem:**
The 1MB size check only runs when `body_length()` is present. If a client sends a chunked/no-length body, the server reads unbounded content into a `String`, allowing excessive memory use and potential local DoS.

**Evidence:**
`MAX_BODY_BYTES` check is conditional on `if let Some(len) = request.body_length()`, then unconditional `read_to_string` follows.

**Recommendation:**
Wrap reader with `.take(MAX_BODY_BYTES + 1)` and reject if bytes exceed limit after read, independent of `Content-Length`.

# Subsystem Audit: Setup, Health, and Project Discovery

### [SETUP] Finding 1: Hook binary verification invokes removed CLI shape

**Severity:** High  
**Type:** Design flaw  
**Location:** `core/capacitor-core/src/runtime_setup.rs:339-365`, `core/hud-hook/src/main.rs:42-65`

**Problem:**
`verify_hook_binary` runs `hud-hook handle`, but `hud-hook` only exposes `serve` and `cwd`. This means verification no longer checks a real supported command path and can report success without validating operational hook modes.

**Evidence:**
Runtime setup passes non-137 exits as success, while CLI definition has no `handle` subcommand.

**Recommendation:**
Validate with supported commands (`--version` plus a lightweight `cwd` invocation) or an end-to-end `serve` health probe on an ephemeral port.

### [HEALTH] Finding 2: Hook-health grace can be incorrectly extended by stale sessions

**Severity:** Medium  
**Type:** Design flaw  
**Location:** `core/capacitor-core/src/lib.rs:225-237`, `core/capacitor-core/src/runtime_state/snapshot.rs:84-97`

**Problem:**
Health grace logic depends on "active session" detection. Snapshot conversion forces `is_alive = Some(true)` for all sessions, and health treats any non-`idle` state as active. This can classify stale sessions as active and mask stale-heartbeat status during grace windows.

**Evidence:**
`sessions_snapshot` hardcodes `is_alive: Some(true)`; `has_active_runtime_session` uses `!matches!(state, "idle")`.

**Recommendation:**
Only treat `working|waiting|compacting` as active, and avoid forced alive=true (derive from PID checks or timestamp freshness heuristics).

### [PROJECT DISCOVERY] Finding 3: Sort order does not match claimed "most recent activity"

**Severity:** Medium  
**Type:** Bug  
**Location:** `core/capacitor-core/src/runtime_projects.rs:258-286`

**Problem:**
The function claims projects are sorted by recent activity, but it sorts by the Claude project directory mtime. Directory mtime may not change when existing JSONL files are appended, so ordering can be wrong.

**Evidence:**
`sort_time` is derived from `claude_project_dir.metadata().modified()`, not from latest session file mtime.

**Recommendation:**
Use the latest non-agent `.jsonl` file mtime (same source used for `last_active`) for ordering.

### [VALIDATION] Finding 4: Cargo metadata extraction is not scoped to `[package]`

**Severity:** Low  
**Type:** Bug  
**Location:** `core/capacitor-core/src/runtime_validation.rs:333-359`

**Problem:**
`extract_cargo_toml_info` regex-scans all lines and captures first `name=` / `description=` matches anywhere. In complex TOMLs this can extract incorrect metadata from non-package sections.

**Evidence:**
No section tracking or TOML AST parsing is used.

**Recommendation:**
Parse with a TOML parser and read `[package].name` and `[package].description` explicitly.

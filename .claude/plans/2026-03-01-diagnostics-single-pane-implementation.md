# Diagnostics Single Pane of Glass — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Consolidate 5 overlapping diagnostic layers into `agent-observe.sh` as the single canonical diagnostic entry point for coding agents.

**Architecture:** Make `agent-observe.sh` fully self-sufficient by reading the runtime snapshot file directly (no Node server dependency). Delete the Makefile indirection layer, dead endpoints, and vestigial docs. Promote `DiagnosticsSnapshotLogger` to release builds. Merge two overlapping doc files into one.

**Tech Stack:** Bash (agent-observe.sh), Swift (DiagnosticsSnapshotLogger), Node.js (transparent-ui-server cleanup), Markdown (docs)

---

### Task 1: Delete the Makefile

The entire Makefile is 137 lines of `observe-*` targets that wrap `agent-observe.sh` 1:1. Three targets are broken/dead:
- `observe-sql` — no `sql` command exists in agent-observe.sh
- `observe-tail-daemon-stderr` / `observe-tail-daemon-stdout` — pass wrong names (`daemon-stderr` vs `runtime-stderr`)

CLAUDE.md already points agents to `agent-observe.sh` directly.

**Files:**
- Delete: `Makefile`

**Step 1: Verify nothing else references the Makefile**

Run: `grep -r 'make observe\|make help\|Makefile' --include='*.md' --include='*.sh' --include='*.swift' . | grep -v '.git/' | grep -v 'node_modules'`

The only references should be in CLAUDE.md (which we update in Task 8) and possibly rewrite artifacts.

**Step 2: Delete the Makefile**

```bash
rm Makefile
```

**Step 3: Port observe-smoke to agent-observe.sh**

The Makefile's `observe-smoke` is a useful compound check. Port it to agent-observe.sh as the `smoke` command. Add this case to the case statement in `scripts/dev/agent-observe.sh` (before the `*` catch-all at line 238):

```bash
  smoke)
    project_path="${1:-$(pwd)}"
    workspace_id="${2:-}"
    echo "Running observability smoke checks..."
    set -e
    "$0" check >/dev/null && echo "  ok check"
    "$0" health >/dev/null && echo "  ok health"
    "$0" projects >/dev/null && echo "  ok projects"
    "$0" sessions >/dev/null && echo "  ok sessions"
    "$0" shells >/dev/null && echo "  ok shells"
    "$0" snapshot >/dev/null && echo "  ok snapshot"
    if [[ -n "$project_path" ]]; then
      "$0" routing-snapshot "$project_path" "$workspace_id" >/dev/null && echo "  ok routing-snapshot ($project_path)"
      "$0" routing-diagnostics >/dev/null && echo "  ok routing-diagnostics"
    fi
    echo "Observability smoke checks passed."
    ;;
```

Also add `smoke` to the usage help text (line 31 area).

**Step 4: Run smoke to verify it works**

```bash
./scripts/dev/agent-observe.sh smoke
```

Expected: all checks pass (or graceful failures if runtime not active).

**Step 5: Commit**

```bash
git rm Makefile
git add scripts/dev/agent-observe.sh
git commit -m "refactor(diag): delete Makefile indirection, port smoke to agent-observe.sh"
```

---

### Task 2: Delete vestigial transparent-ui docs and dead endpoint

**Files:**
- Delete: `docs/transparent-ui/README.md`
- Delete: `docs/transparent-ui/capacitor-interfaces-explorer.html`
- Delete: `scripts/run-transparent-ui.sh`
- Modify: `scripts/transparent-ui-server.mjs:365-374` (remove `/routing-rollout` handler)
- Modify: `scripts/transparent-ui-server.mjs:408-420` (remove `routingRollout` from root endpoint listing)
- Modify: `scripts/transparent-ui-server.mjs:253-259` (remove `routingRollout` from briefing endpoints)

**Step 1: Delete the docs directory and launcher script**

```bash
rm -r docs/transparent-ui/
rm scripts/run-transparent-ui.sh
```

If `docs/` is now empty, remove it too.

**Step 2: Remove /routing-rollout endpoint from transparent-ui-server.mjs**

Delete lines 365-374 (the `/routing-rollout` handler):

```javascript
  // DELETE THIS BLOCK:
  if (req.url.startsWith("/routing-rollout")) {
    jsonResponse(res, 200, {
      ok: true,
      timestamp: new Date().toISOString(),
      routing: null,
      rollout: null,
      note: "rollout metrics removed in direct-core mode"
    });
    return;
  }
```

Also remove `routingRollout: "/routing-rollout"` from the two `endpoints` objects:
- Line 258 in `buildBriefing`
- Line 416 in the root handler

**Step 3: Verify server still starts**

```bash
node scripts/transparent-ui-server.mjs &
SERVER_PID=$!
curl -s http://localhost:9133/ | jq .endpoints
kill $SERVER_PID
```

Expected: endpoints object without `routingRollout`.

**Step 4: Commit**

```bash
git rm -r docs/transparent-ui/
git rm scripts/run-transparent-ui.sh
git add scripts/transparent-ui-server.mjs
git commit -m "refactor(diag): delete vestigial transparent-ui docs and dead routing-rollout endpoint"
```

---

### Task 3: Make agent-observe.sh `briefing` self-sufficient

Currently `briefing` calls `http_get_json` which requires the transparent-ui-server. Replace with a direct snapshot read that formats a useful agent summary.

**Files:**
- Modify: `scripts/dev/agent-observe.sh:205-208`

**Step 1: Replace the briefing command**

Replace the current briefing case (lines 205-208):

```bash
  briefing)
    limit="${1:-200}"
    http_get_json "${TRANSPARENT_UI_BASE_URL}/agent-briefing?limit=${limit}"
    ;;
```

With a self-sufficient version:

```bash
  briefing)
    if command -v jq >/dev/null 2>&1; then
      read_snapshot | jq '{
        ok: true,
        summary: {
          projects: { count: (.projects | length), paths: [.projects[].project_path] },
          sessions: {
            count: (.sessions | length),
            states: ([.sessions[].state] | group_by(.) | map({(.[0]): length}) | add // {}),
            working: [.sessions[] | select(.state == "working") | {session_id, project_path, updated_at, tools_in_flight}]
          },
          shells: { count: (.shells | length) },
          routing: [.routing[] | {project_path, status, target_kind, target_value, reason_code}],
          diagnostics: .diagnostics,
          generated_at: .generated_at
        }
      }'
    else
      read_snapshot
    fi
    ;;
```

**Step 2: Test without server running**

```bash
# Ensure no transparent-ui-server is running
./scripts/dev/agent-observe.sh briefing
```

Expected: JSON summary of current runtime state, without needing the Node server.

**Step 3: Commit**

```bash
git add scripts/dev/agent-observe.sh
git commit -m "refactor(diag): make briefing command self-sufficient via direct snapshot read"
```

---

### Task 4: Make agent-observe.sh `snapshot` and `telemetry` self-sufficient

**Files:**
- Modify: `scripts/dev/agent-observe.sh:198-215`

**Step 1: Simplify snapshot command**

Replace lines 198-203 (the snapshot case that tries server first):

```bash
  snapshot)
    if curl -fsS "${TRANSPARENT_UI_BASE_URL}/runtime-snapshot" >/dev/null 2>&1; then
      http_get_json "${TRANSPARENT_UI_BASE_URL}/runtime-snapshot"
    else
      read_snapshot | pretty_print_json
    fi
    ;;
```

With:

```bash
  snapshot)
    read_snapshot | pretty_print_json
    ;;
```

**Step 2: Make telemetry gracefully degrade**

Replace lines 209-211 (the telemetry case):

```bash
  telemetry)
    limit="${1:-200}"
    http_get_json "${TRANSPARENT_UI_BASE_URL}/telemetry?limit=${limit}"
    ;;
```

With:

```bash
  telemetry)
    limit="${1:-200}"
    if curl -fsS "${TRANSPARENT_UI_BASE_URL}/telemetry?limit=${limit}" 2>/dev/null | pretty_print_json; then
      :
    else
      echo "Telemetry requires transparent-ui-server (node scripts/transparent-ui-server.mjs)" >&2
      exit 1
    fi
    ;;
```

**Step 3: Simplify check command — remove server reachability**

In the `check()` function (lines 76-113), remove lines 104-109:

```bash
  echo "Transparent UI: $TRANSPARENT_UI_BASE_URL"
  if curl -fsS "${TRANSPARENT_UI_BASE_URL}/runtime-snapshot" >/dev/null 2>&1; then
    echo "  ok (reachable)"
  else
    echo "  not reachable"
  fi
```

And remove the `TRANSPARENT_UI_BASE_URL` variable declaration from the top of the file (line 10).

Also remove transparent-ui references from the `paths()` function (lines 122-127).

**Step 4: Test**

```bash
./scripts/dev/agent-observe.sh check
./scripts/dev/agent-observe.sh snapshot
./scripts/dev/agent-observe.sh telemetry  # expect graceful error without server
```

**Step 5: Commit**

```bash
git add scripts/dev/agent-observe.sh
git commit -m "refactor(diag): remove transparent-ui-server dependency from core commands"
```

---

### Task 5: Add `freshness`, `errors`, and `hooks` commands

**Files:**
- Modify: `scripts/dev/agent-observe.sh` (add 3 new case blocks + help text)

**Step 1: Add freshness command**

Add before the `*` catch-all:

```bash
  freshness)
    if [[ ! -f "$SNAPSHOT_PATH" ]]; then
      echo '{"ok":false,"error":"snapshot_missing","age_seconds":null}' | pretty_print_json
      exit 1
    fi
    if command -v jq >/dev/null 2>&1; then
      generated_at=$(jq -r '.generated_at // empty' "$SNAPSHOT_PATH" 2>/dev/null)
      if [[ -n "$generated_at" ]]; then
        generated_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$generated_at" "+%s" 2>/dev/null || date -d "$generated_at" "+%s" 2>/dev/null || echo "")
        if [[ -n "$generated_epoch" ]]; then
          now_epoch=$(date "+%s")
          age=$(( now_epoch - generated_epoch ))
          stale="false"
          if [[ "$age" -gt 30 ]]; then stale="true"; fi
          jq -n --argjson age "$age" --argjson stale "$stale" --arg generated_at "$generated_at" \
            '{ok:true, age_seconds:$age, stale:$stale, generated_at:$generated_at}'
        else
          echo '{"ok":true,"age_seconds":null,"note":"could not parse generated_at"}' | pretty_print_json
        fi
      else
        echo '{"ok":true,"age_seconds":null,"note":"no generated_at in snapshot"}' | pretty_print_json
      fi
    else
      stat -f "%m" "$SNAPSHOT_PATH" 2>/dev/null || echo "jq required for detailed freshness"
    fi
    ;;
```

**Step 2: Add errors command**

```bash
  errors)
    limit="${1:-20}"
    if [[ ! -f "$APP_LOG_PATH" ]]; then
      echo "No app debug log found: $APP_LOG_PATH" >&2
      exit 1
    fi
    grep -i -E 'error|fail|crash|fatal' "$APP_LOG_PATH" | tail -n "$limit"
    ;;
```

**Step 3: Add hooks command**

```bash
  hooks)
    echo "Hook binary:"
    hook_path="${HOME}/.local/bin/hud-hook"
    if [[ -L "$hook_path" ]]; then
      target=$(readlink "$hook_path")
      if [[ -x "$hook_path" ]]; then
        echo "  ok (symlink -> $target)"
      else
        echo "  broken symlink (-> $target)"
      fi
    elif [[ -x "$hook_path" ]]; then
      echo "  ok (binary)"
    else
      echo "  missing ($hook_path)"
    fi
    echo ""
    echo "Recent hook events (from debug log):"
    if [[ -f "$APP_LOG_PATH" ]]; then
      grep -i -E 'hook|hud-hook|shell.integration|startup' "$APP_LOG_PATH" | tail -n 20
    else
      echo "  (no debug log found)"
    fi
    ;;
```

**Step 4: Update usage help text**

Add to the usage block (around line 31):

```
  freshness                              Snapshot age and staleness check
  errors [limit]                         Recent error lines from app debug log (default=20)
  hooks                                  Hook installation status + recent events
  smoke [project_path] [workspace_id]    Run all observability smoke checks
```

**Step 5: Test each command**

```bash
./scripts/dev/agent-observe.sh freshness
./scripts/dev/agent-observe.sh errors
./scripts/dev/agent-observe.sh errors 5
./scripts/dev/agent-observe.sh hooks
```

**Step 6: Commit**

```bash
git add scripts/dev/agent-observe.sh
git commit -m "feat(diag): add freshness, errors, and hooks diagnostic commands"
```

---

### Task 6: Add `diagnose` one-shot command

This is the "single pane of glass" — one command that runs all diagnostics and prints a summary.

**Files:**
- Modify: `scripts/dev/agent-observe.sh`

**Step 1: Add diagnose command**

Add before the `*` catch-all:

```bash
  diagnose)
    echo "=== Capacitor Diagnostics ==="
    echo ""

    echo "--- Freshness ---"
    "$0" freshness 2>/dev/null || echo '{"ok":false,"error":"freshness check failed"}'
    echo ""

    echo "--- Health ---"
    "$0" health 2>/dev/null || echo '{"ok":false,"error":"health check failed"}'
    echo ""

    echo "--- Stuck Sessions ---"
    if command -v jq >/dev/null 2>&1 && [[ -f "$SNAPSHOT_PATH" ]]; then
      stuck=$(jq '[.sessions[] | select(.state == "working") | select(
        (.updated_at // "" | length) > 0 and
        ((now - ((.updated_at // "1970-01-01T00:00:00Z") | fromdateiso8601)) > 30)
      ) | {session_id, project_path, state, updated_at, tools_in_flight}]' "$SNAPSHOT_PATH" 2>/dev/null)
      count=$(echo "$stuck" | jq 'length' 2>/dev/null || echo "0")
      if [[ "$count" -gt 0 ]]; then
        echo "  WARNING: $count potentially stuck session(s):"
        echo "$stuck" | jq .
      else
        echo "  ok (no stuck sessions)"
      fi
    else
      echo "  (requires jq + snapshot)"
    fi
    echo ""

    echo "--- Recent Errors ---"
    if [[ -f "$APP_LOG_PATH" ]]; then
      error_count=$(grep -c -i -E 'error|fail|crash|fatal' "$APP_LOG_PATH" 2>/dev/null || echo "0")
      echo "  Total error lines: $error_count"
      if [[ "$error_count" -gt 0 ]]; then
        echo "  Last 5:"
        grep -i -E 'error|fail|crash|fatal' "$APP_LOG_PATH" | tail -n 5 | sed 's/^/    /'
      fi
    else
      echo "  (no debug log)"
    fi
    echo ""

    echo "--- Hooks ---"
    "$0" hooks 2>/dev/null | sed 's/^/  /'
    echo ""

    echo "--- Routing Summary ---"
    if command -v jq >/dev/null 2>&1 && [[ -f "$SNAPSHOT_PATH" ]]; then
      jq '.routing | map({project_path, status, target_kind, reason_code})' "$SNAPSHOT_PATH" 2>/dev/null || echo "  (parse error)"
    else
      echo "  (requires jq + snapshot)"
    fi
    echo ""
    echo "=== End Diagnostics ==="
    ;;
```

**Step 2: Update usage help**

Add to usage block:

```
  diagnose                               One-shot full diagnostic summary
```

**Step 3: Test**

```bash
./scripts/dev/agent-observe.sh diagnose
```

Expected: Multi-section diagnostic output covering freshness, health, stuck sessions, errors, hooks, and routing.

**Step 4: Commit**

```bash
git add scripts/dev/agent-observe.sh
git commit -m "feat(diag): add diagnose one-shot command — the single pane of glass"
```

---

### Task 7: Promote DiagnosticsSnapshotLogger to release builds

**Files:**
- Modify: `apps/swift/Sources/Capacitor/Utilities/DiagnosticsSnapshotLogger.swift:1-213`
- Modify: `apps/swift/Sources/Capacitor/Models/SessionStateManager.swift:152-154`
- Modify: `apps/swift/Sources/Capacitor/Models/AppState.swift:402-406`

**Step 1: Remove #if DEBUG gate from DiagnosticsSnapshotLogger.swift**

In `DiagnosticsSnapshotLogger.swift`:
- Delete line 15: `#if DEBUG`
- Delete line 213: `#endif`

**Step 2: Add log rotation**

Add rotation to the `append` method (lines 201-211). Replace with:

```swift
private enum LogLimits {
    static let maxBytes = 5 * 1024 * 1024    // 5MB
    static let retainBytes = 1 * 1024 * 1024  // 1MB
}

private static func append(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    try trimIfNeeded(url: url)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
}

private static func trimIfNeeded(url: URL) throws {
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = (attrs[.size] as? NSNumber)?.int64Value, size > Int64(LogLimits.maxBytes) else { return }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let start = max(Int64(0), size - Int64(LogLimits.retainBytes))
    try handle.seek(toOffset: UInt64(start))
    let tail = try handle.readToEnd() ?? Data()
    try tail.write(to: url, options: .atomic)
}
```

**Step 3: Remove #if DEBUG guards at call sites**

In `SessionStateManager.swift`, replace lines 152-154:
```swift
#if DEBUG
    DiagnosticsSnapshotLogger.maybeCaptureStuckSessions(sessionStates: stabilized)
#endif
```
With:
```swift
DiagnosticsSnapshotLogger.maybeCaptureStuckSessions(sessionStates: stabilized)
```

In `AppState.swift`, replace lines 402-406:
```swift
#if DEBUG
    DiagnosticsSnapshotLogger.updateContext(
        activeProjectPath: activeProjectPath,
        activeSource: activeSource,
    )
```
With:
```swift
DiagnosticsSnapshotLogger.updateContext(
    activeProjectPath: activeProjectPath,
    activeSource: activeSource,
)
```
(Also remove the corresponding `#endif` line after the closing paren.)

**Step 4: Remove the "TRANSPARENT-UI DEBUG TOOL" comment header**

Delete lines 3-14 of `DiagnosticsSnapshotLogger.swift` (the block comment saying "Remove when no longer needed").

**Step 5: Build and test**

```bash
cd apps/swift && swift build
swift test
```

Expected: 253+ tests pass, no compiler errors.

**Step 6: Commit**

```bash
git add apps/swift/Sources/Capacitor/Utilities/DiagnosticsSnapshotLogger.swift
git add apps/swift/Sources/Capacitor/Models/SessionStateManager.swift
git add apps/swift/Sources/Capacitor/Models/AppState.swift
git commit -m "feat(diag): promote DiagnosticsSnapshotLogger to release builds with 5MB rotation"
```

---

### Task 8: Merge documentation and update CLAUDE.md

**Files:**
- Modify: `.claude/docs/debugging-guide.md`
- Delete: `.claude/docs/agent-observability-runbook.md`
- Modify: `CLAUDE.md:71-89`

**Step 1: Write merged debugging guide**

Replace `.claude/docs/debugging-guide.md` with:

```markdown
# Debugging Guide

## Core Model

Capacitor is runtime-snapshot based:

1. `hud-hook` ingests events.
2. `capacitor-core` projects state.
3. Swift reads typed snapshot data and renders UI.

## Canonical Diagnostic Tool

```bash
# One-shot full diagnostic summary
./scripts/dev/agent-observe.sh diagnose

# Individual commands
./scripts/dev/agent-observe.sh check       # Validate runtime paths
./scripts/dev/agent-observe.sh health      # Runtime health from snapshot
./scripts/dev/agent-observe.sh freshness   # Snapshot age + staleness
./scripts/dev/agent-observe.sh sessions    # Session summaries
./scripts/dev/agent-observe.sh projects    # Project summaries
./scripts/dev/agent-observe.sh shells      # Shell summaries
./scripts/dev/agent-observe.sh routing-snapshot <path> [ws]  # Routing entry
./scripts/dev/agent-observe.sh errors      # Recent errors from debug log
./scripts/dev/agent-observe.sh hooks       # Hook status + recent events
./scripts/dev/agent-observe.sh briefing    # Agent-friendly summary
./scripts/dev/agent-observe.sh snapshot    # Full runtime snapshot
./scripts/dev/agent-observe.sh smoke       # Run all smoke checks
```

## Activation Debugging

1. Reproduce with a known project card click.
2. Inspect routing block in snapshot (`.routing`).
3. Verify shell evidence in `.shells` and session evidence in `.sessions`.
4. Run `apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift` when policy changes.

## Hook Debugging

1. Run `./scripts/dev/agent-observe.sh hooks` for status.
2. Verify binary: `~/.local/bin/hud-hook --help`
3. Verify hook install via setup screen / hook diagnostics.
4. Confirm snapshot updates after shell cwd changes.

## If State Looks Wrong

1. Run `./scripts/dev/agent-observe.sh diagnose` first.
2. Validate reducer determinism (`cargo test -p capacitor-core --test replay_diff`).
3. Validate mapping integrity (`cargo test -p hud-hook --test session_state_mapping_gate`).
4. Check reliability gates (`bash scripts/ci/session-state-gate.sh`).
5. Capture snapshot payload and attach to bug report.

## Optional: Transparent UI Server

For browser-based exploration (not required for CLI diagnostics):

```bash
node scripts/transparent-ui-server.mjs  # http://localhost:9133
```

Endpoints: `/runtime-snapshot`, `/agent-briefing`, `/telemetry`, `/telemetry-stream`
```

**Step 2: Delete the runbook**

```bash
rm .claude/docs/agent-observability-runbook.md
```

**Step 3: Update CLAUDE.md Telemetry section**

Replace CLAUDE.md lines 71-89 with:

```markdown
## Telemetry

For coding-agent runtime debugging, use the canonical diagnostic CLI:

```bash
./scripts/dev/agent-observe.sh diagnose   # One-shot full diagnostics
./scripts/dev/agent-observe.sh check      # Validate paths
./scripts/dev/agent-observe.sh health     # Runtime health
./scripts/dev/agent-observe.sh freshness  # Snapshot staleness
```

Full command reference: `./scripts/dev/agent-observe.sh help`
Debugging guide: `.claude/docs/debugging-guide.md`

Optional browser UI: `node scripts/transparent-ui-server.mjs` (localhost:9133)
```

**Step 4: Commit**

```bash
git add .claude/docs/debugging-guide.md
git rm .claude/docs/agent-observability-runbook.md
git add CLAUDE.md
git commit -m "docs(diag): merge debugging docs, update CLAUDE.md to single diagnostic entry point"
```

---

### Task 9: Final verification and cleanup

**Step 1: Run full test suite**

```bash
cargo test
cd apps/swift && swift test
```

Expected: All Rust and Swift tests pass.

**Step 2: Run the new smoke command**

```bash
./scripts/dev/agent-observe.sh smoke
```

**Step 3: Run diagnose to verify end-to-end**

```bash
./scripts/dev/agent-observe.sh diagnose
```

**Step 4: Verify no dangling references**

```bash
grep -r 'observe-smoke\|make observe\|Makefile' --include='*.md' --include='*.sh' --include='*.swift' . | grep -v '.git/'
grep -r 'agent-observability-runbook' --include='*.md' --include='*.sh' . | grep -v '.git/'
grep -r 'routing-rollout' --include='*.mjs' --include='*.md' --include='*.sh' . | grep -v '.git/'
grep -r 'run-transparent-ui' --include='*.md' --include='*.sh' . | grep -v '.git/'
```

Fix any remaining references found.

**Step 5: Final commit if needed**

```bash
git add -A
git commit -m "chore(diag): fix remaining dangling references from diagnostics audit"
```

**Step 6: Push**

```bash
git push
```

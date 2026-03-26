# Checkpoint Flow Investigation

Date: 2026-03-25 America/Los_Angeles

## Verdict

I could not verify the checkpoint review flow end-to-end from this Codex environment.

What I **did** verify:

- The debug Capacitor app is running.
- The bundled `hud-hook` runtime service is listening on `127.0.0.1:7474`.
- The app is actively polling runtime snapshots and sees `runs=5`.
- The persisted snapshot currently has `0` active checkpoints.

What I **could not** verify:

- Creating a run via `POST /runtime/run/mutate`
- Emitting a checkpoint via `POST /runtime/run/mutate`
- Detecting the review window via AX automation

Both blocked steps failed because of the investigation environment, not because of a confirmed application bug:

- HTTP to `127.0.0.1:7474` is unreachable from this sandboxed shell even though `lsof` shows a live listener.
- AX automation from this shell is not trusted by macOS Accessibility.

## Step-by-Step Outcomes

### Step 1: Read bootstrap

Command:

```bash
cat ~/.capacitor/runtime/bootstrap.json 2>/dev/null || echo "No bootstrap found"
```

Outcome: `bootstrap.json` was not present.

Raw output:

```text
No bootstrap found
```

Notes:

- This install appears to use `~/.capacitor/runtime/runtime-service.json` as the live connection file instead.
- That file contained:

```json
{"port":7474,"auth_token":"CB8C40DF-BE56-4F40-876A-1994614E1A35"}
```

### Step 2: Check runtime service health

Command:

```bash
curl -s http://127.0.0.1:7474/health 2>/dev/null || echo "Service not reachable"
```

Outcome: failed from this shell.

Raw output:

```text
Service not reachable
```

I also retried with the auth token:

```bash
TOKEN=$(jq -r '.auth_token' ~/.capacitor/runtime/runtime-service.json)
curl -i -sS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7474/health
```

Raw output:

```text
curl: (7) Failed to connect to 127.0.0.1 port 7474 after 0 ms: Couldn't connect to server
```

### Step 3: Check whether the app is running

Initial command:

```bash
pgrep -fl "Capacitor" || echo "App not running"
```

Initial outcome: misleading failure due sandbox/process-list limitations.

Raw output:

```text
sysmon request failed with error: sysmond service not found
pgrep: Cannot get process list
App not running
```

Follow-up with `ps`:

```bash
ps -axo pid,comm,args | rg 'Capacitor|hud-hook'
```

Confirmed outcome: the app and runtime service are both running.

Relevant lines:

```text
79370 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/MacOS/Capacitor
79435 /Users/petepetrash/Code/capacitor/apps/swift/CapacitorDebug.app/Contents/Resources/hud-hook serve --port 7474
```

### Step 4: Restart the app if needed

Attempted command:

```bash
cd /Users/petepetrash/Code/capacitor
./scripts/dev/restart-alpha-frontier.sh
```

Outcome: direct restart failed in this environment.

First failure:

```text
Warning: No Apple signing identity found. Falling back to ad-hoc signing.
/Users/petepetrash/Code/capacitor/scripts/dev/restart-app.sh: line 323: /Users/petepetrash/.capacitor/runtime-context.env: Operation not permitted
```

I retried with shell-side runtime writes redirected into `/tmp`:

```bash
CAPACITOR_RUNTIME_STATE_PERSIST=0 \
CAPACITOR_RUNTIME_DIR=/tmp/capacitor-runtime-investigation \
CAPACITOR_LEGACY_DAEMON_SOCKET=/tmp/capacitor-daemon-investigation.sock \
CAPACITOR_LEGACY_DAEMON_DIR=/tmp/capacitor-daemon-investigation \
./scripts/dev/restart-alpha-frontier.sh
```

That got further, but still failed during process cleanup:

```text
sysmon request failed with error: sysmond service not found
pgrep: Cannot get process list
Reaping stale runtime service on port 7474...
Error: Port 7474 is still occupied after runtime service cleanup.
```

Important nuance:

- This was not a proof that the app was down.
- The app was already running, and the live service listener was still present.

### Step 5: Find a project path from the runtime snapshot

Planned command:

```bash
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:7474/runtime/snapshot
```

Outcome: blocked by the same loopback connectivity failure.

Raw output:

```text
curl: (7) Failed to connect to 127.0.0.1 port 7474 after 0 ms: Couldn't connect to server
```

Fallback evidence from the persisted runtime artifact:

```bash
jq '{run_count:(.runs|length), active_checkpoint_runs:[.runs[] | select(.active_checkpoint != null) | {id,project_path,status,checkpoint_id:.active_checkpoint.id,title:.active_checkpoint.title,kind:.active_checkpoint.kind}]}' ~/.capacitor/runtime/app_snapshot.json
```

Output:

```json
{
  "run_count": 5,
  "active_checkpoint_runs": []
}
```

This is **not** a runtime-service query, but it does confirm the persisted runtime state had no active checkpoint at the time of investigation.

### Step 6: Create a test run via the runtime service

Planned endpoint:

```text
POST /runtime/run/mutate
```

Outcome: not executed, because the shell could not connect to `127.0.0.1:7474`.

### Step 7: Emit a checkpoint on that run

Planned endpoint:

```text
POST /runtime/run/mutate
```

Outcome: not executed, because the shell could not connect to `127.0.0.1:7474`.

### Step 8: Wait for the app to pick up the checkpoint

Outcome: not testable, because Steps 6 and 7 could not be executed.

What I could verify instead:

- The app is actively reconciling runtime snapshots.
- The app debug log shows current snapshots include `runs=5`.

Example line from `~/.capacitor/runtime/app-debug.log`:

```text
[2026-03-26T03:53:03.704Z] AppState.refreshSessionStates source=runtime_snapshot_apply cid=app-snap-38 projects=52 sessions=80 shells=668 routing=11 runs=5
```

### Step 9: Check for the review window via AX

Attempted command:

```bash
swift -module-cache-path /tmp/capacitor-swift-module-cache \
  /Users/petepetrash/Code/capacitor/scripts/ax/ax_runner.swift \
  --bundle-id com.capacitor.app.debug \
  --scenario /dev/stdin <<'SCENARIO'
{"steps": [
  {"type": "wait", "duration": 1},
  {"type": "click", "identifier": "ax.run-checkpoint-review.approve", "timeout": 3}
]}
SCENARIO
```

Outcome: AX automation blocked by Accessibility trust.

Raw output:

```text
ax_runner error: Accessibility permission is required for AX automation.
{"bundleID":"com.capacitor.app.debug","clickMode":"scenario","event":"runner.start","scenarioPath":"\/dev\/stdin","stepCount":2,"ts":"2026-03-26T03:50:07.362Z"}
{"event":"runner.error","message":"Accessibility permission is required for AX automation.","ts":"2026-03-26T03:50:07.366Z"}
```

I also tried AppleScript/System Events access and that was not usable from this environment either.

### Step 10: Record findings

Answers to the key questions:

1. Is the runtime service running and reachable?
   - Running: **yes**
   - Reachable from this Codex shell: **no**
   - Evidence: `lsof` shows `hud-hook` listening on `127.0.0.1:7474`, but `curl` fails with `curl: (7) Failed to connect`

2. Did the run creation mutation succeed?
   - **Not attempted**, because the runtime service was unreachable from this shell

3. Did the checkpoint emission mutation succeed?
   - **Not attempted**, because the runtime service was unreachable from this shell

4. Does the snapshot show the run as paused with active checkpoint?
   - **No evidence of that state**
   - Persisted snapshot at investigation time showed `active_checkpoint_runs: []`

5. Did the checkpoint review window appear in the UI?
   - **Not verified**
   - AX automation was blocked by macOS Accessibility trust

6. If not, what is blocking it?
   - Primary blocker 1: loopback HTTP from this shell to the live runtime service
   - Primary blocker 2: AX automation trust for the current shell process

### Step 11: Check debug log for clues

Command:

```bash
tail -200 ~/.capacitor/runtime/app-debug.log | grep -iE 'checkpoint|review|paused'
```

Outcome:

```text
No checkpoint/review/paused lines in tail
```

This matches the persisted snapshot result: there was no active checkpoint during the investigation window.

## Additional Evidence

### Live listener confirmation

Command:

```bash
lsof -nP -iTCP:7474 -sTCP:LISTEN
```

Output:

```text
COMMAND    PID        USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
hud-hook 79435 petepetrash    4u  IPv4 0xd12de684adf6de24      0t0  TCP 127.0.0.1:7474 (LISTEN)
```

### App-visible runtime integration is active

The app debug log repeatedly showed runtime snapshot application with `runs=5`, so the live app-to-runtime polling path is active.

### Current UI window baseline

I also queried WindowServer from a Swift script as a non-AX fallback and found no visible Capacitor windows at the time of inspection:

```text
NO_WINDOWS
```

That does **not** prove anything about checkpoint behavior by itself, but it does mean this session did not start from an already-open main window.

## Relevant Implementation Hooks

These code paths are relevant once the environment blockers are removed:

- The `Run Checkpoint` window is registered in `App.swift`.
- A paused run with an active checkpoint is treated as eligible in `AppState.reconcileRunCheckpointWindowTarget`.
- The window opens when `runCheckpointWindowTarget?.checkpointID` changes from `nil` to a value in `ProjectsView`.
- The review window root view exposes AX identifier `ax.run-checkpoint-review`.

Source references:

- `apps/swift/Sources/Capacitor/App.swift:178`
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1881`
- `apps/swift/Sources/Capacitor/Models/AppState.swift:1922`
- `apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift:266`
- `apps/swift/Sources/Capacitor/Views/Projects/RunCheckpointReviewWindow.swift:81`

## Diagnosis

The investigation did **not** find an application-layer failure in the checkpoint review flow itself.

Instead, the investigation broke at the tooling boundary:

- The live runtime service exists, but this Codex shell cannot connect to its loopback port.
- The live app exists, but this Codex shell is not trusted for Accessibility automation.

Because of those two blockers, I could not produce the one piece of evidence that matters most:

- a successful `emit_checkpoint` mutation on the live runtime service
- followed by direct observation of the `Run Checkpoint` window opening

## Recommended Next Steps

1. Re-run the same investigation from an unrestricted host terminal, not from this sandboxed Codex shell.
2. Grant Accessibility to the process running `scripts/ax/ax_runner.swift` before re-running Step 9.
3. Use `~/.capacitor/runtime/runtime-service.json` as the connection source if `bootstrap.json` is absent.
4. Add a narrow debug log around `runCheckpointWindowTarget` changes so future vertical-slice tests can prove window-trigger behavior without depending entirely on AX.
5. If this needs to be CI/agent-friendly, add a repo-supported local mutation CLI that talks to the same reducer/storage without requiring live loopback HTTP.

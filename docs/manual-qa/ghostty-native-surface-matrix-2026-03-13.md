# Ghostty Native Surface Matrix - 2026-03-13

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

## Goal

Re-test whether Ghostty 1.3.0's native AppleScript surface-creation API was sufficient to replace the last legacy Ghostty launch path for both running-Ghostty and cold-start flows.

## Scope

- Tested both with Ghostty already running and from a not-running cold-start state.
- Focused on the behaviors we would need for full launch/resume migration:
  - create a new tab
  - create a new window
  - set initial working directory
  - execute launch input or a launch command
  - attach a tmux session as the launched workload

## Environment

- Ghostty version: `1.3.0`
- Test working directory root:
  - `/var/folders/hs/xnk080153dn7fq5qk9bk3g7w0000gn/T/ghostty-applescript-matrix-7gz5afrg`
  - `/var/folders/hs/xnk080153dn7fq5qk9bk3g7w0000gn/T/ghostty-applescript-tmux-adeyubny`
  - `/var/folders/hs/xnk080153dn7fq5qk9bk3g7w0000gn/T/ghostty-coldstart-matrix-ryxddcn0`

## Matrix

### Running Ghostty

| Case | Result | Evidence |
|---|---|---|
| `new tab` + `initial working directory` | Pass | Ghostty reported the created terminal cwd as the requested temp workdir |
| `new window` + `initial working directory` | Pass | Ghostty reported the created terminal cwd as the requested temp workdir |
| `new tab` + `initial input` writing a marker file | Pass | Marker file was created |
| `new window` + `initial input` writing a marker file | Pass | Marker file was created |
| `new tab` + `command` writing a marker file then `exec /bin/sh` | Pass | Marker file and `pwd` file were created |
| `new window` + `command` writing a marker file then `exec /bin/sh` | Pass | Marker file and `pwd` file were created |
| `new tab` + post-create `input text` | Fail | AppleScript command succeeded, but the marker file was not created |
| `new window` + post-create `input text` | Fail | AppleScript command succeeded, but the marker file was not created |
| `new tab` + `initial input` launching `tmux new-session -A -s ...` | Pass | tmux session created and attached client observed on `/dev/ttys034` |
| `new tab` + `command` launching `tmux new-session -A -s ...` | Pass | tmux session created and attached client observed on `/dev/ttys036` |
| `new window` + `initial input` launching `tmux new-session -A -s ...` | Pass | tmux session created and attached client observed on `/dev/ttys038` |
| `new window` + `command` launching `tmux new-session -A -s ...` | Pass | tmux session created and attached client observed on `/dev/ttys040` |

### Cold-start Ghostty

| Case | Result | Evidence |
|---|---|---|
| `new window` + `initial working directory` from not-running app | Pass | Ghostty launched, created one window, and reported the requested temp workdir |
| `new window` + `initial input` writing a marker file from not-running app | Pass | Ghostty launched, marker file was created |
| `new window` + `command` writing a marker file from not-running app | Pass | Ghostty launched, marker file and `pwd` file were created |
| `new window` + `initial input` launching `tmux new-session -A -s ...` from not-running app | Pass | Ghostty launched, tmux session created, attached client observed on `/dev/ttys009` |
| `new window` + `command` launching `tmux new-session -A -s ...` from not-running app | Pass | Ghostty launched, tmux session created, attached client observed on `/dev/ttys009` |

## Conclusions

- The earlier migration conclusion that Ghostty 1.3.0 native surface creation is not viable is no longer strong enough to treat as current truth.
- On the currently installed Ghostty 1.3.0, `new tab` and `new window` both successfully honor:
  - `initial working directory`
  - `initial input`
  - `command`
- For our actual launch/resume use case, both `initial input` and `command` were sufficient to attach a tmux session in both the running-app and cold-start cases.
- The weak point in this matrix was post-create `input text`; that path did not produce the expected side effect even though the AppleScript call returned success.

## Remaining Uncertainty

- `command` remains a viable Ghostty primitive for future experiments, but Capacitor resolved the UX question in favor of `initial input` so resume flows keep the current shell-first feel.
- We did not test a cold-start `new tab` path because the meaningful cold-start primitive for launch is `new window`.

## Recommendation

- Treat this matrix plus the shipped-implementation smoke below as the proof behind the finished Ghostty launch migration.
- Capacitor now standardizes on `new window` plus `initial working directory` and `initial input` for Ghostty launch/resume.
- Do not build any future Ghostty launch work around post-create `input text`.

## Shipped Implementation Verification

- Post-implementation cold-start smoke:
  - `new window` + `initial input` + `tmux new-session -A -s ...`
  - Result: Pass
  - Evidence: attached client observed on `/dev/ttys015`; pane current path matched `/private/tmp/ghostty-native-launch-proof-sojr9B/cold`
- Post-implementation running-app smoke:
  - `new window` + `initial input` + `tmux new-session -A -s ...`
  - Result: Pass
  - Evidence: attached client observed on `/dev/ttys030`; pane current path matched `/private/tmp/ghostty-native-launch-proof-sojr9B/running`

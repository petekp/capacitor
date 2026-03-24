#!/usr/bin/env bash
# fake-codex.sh — Controllable codex exec test harness.
#
# Emulates the codex exec subprocess contract for adapter integration tests.
# Behavior is controlled entirely via environment variables.
#
# Control variables:
#   FAKE_CODEX_CAPTURE_DIR       — directory to write capture artifacts (required)
#   FAKE_CODEX_READY_FILE        — touch this file when ready (after captures, before sleep)
#   FAKE_CODEX_EXIT_CODE         — exit code to return (default: 0)
#   FAKE_CODEX_SLEEP_SECS        — seconds to sleep before exiting (default: 0)
#   FAKE_CODEX_TERM_MODE         — parent signal mode: default|clean|ignore (default: default)
#   FAKE_CODEX_FORK_DESCENDANT   — if "1", fork a child in the same process group
#   FAKE_CODEX_DESCENDANT_SLEEP_SECS  — how long the descendant sleeps (default: 60)
#   FAKE_CODEX_DESCENDANT_TERM_MODE   — descendant signal mode (default: default)
#   FAKE_CODEX_WRITE_HANDOFF     — if "1", write HANDOFF.md to relay_root (uses -o dir's parent)
#   FAKE_CODEX_WRITE_LAST_MESSAGE — if "1", write to the -o output path
#
# Usage:
#   FAKE_CODEX_CAPTURE_DIR=/tmp/cap FAKE_CODEX_EXIT_CODE=0 \
#     ./fake-codex.sh exec --full-auto -o /tmp/relay/last-message.txt -

set -euo pipefail

# ---------------------------------------------------------------------------
# Parse codex-like argv
# ---------------------------------------------------------------------------
OUTPUT_PATH=""
ARGS=("$@")

i=0
while [ $i -lt ${#ARGS[@]} ]; do
    case "${ARGS[$i]}" in
        -o|--output-last-message)
            i=$((i + 1))
            OUTPUT_PATH="${ARGS[$i]}"
            ;;
    esac
    i=$((i + 1))
done

# ---------------------------------------------------------------------------
# Validate required env
# ---------------------------------------------------------------------------
CAPTURE_DIR="${FAKE_CODEX_CAPTURE_DIR:?FAKE_CODEX_CAPTURE_DIR is required}"
mkdir -p "$CAPTURE_DIR"

# ---------------------------------------------------------------------------
# Capture artifacts
# ---------------------------------------------------------------------------

# argv
printf '%s\n' "$@" > "$CAPTURE_DIR/argv.txt"

# cwd
pwd > "$CAPTURE_DIR/cwd.txt"

# env (sorted for deterministic output)
env | sort > "$CAPTURE_DIR/env.txt"

# stdin — read exactly once, persist for assertions
STDIN_CONTENT=""
if [ "${ARGS[*]: -1}" = "-" ] 2>/dev/null; then
    STDIN_CONTENT="$(cat)"
fi
printf '%s' "$STDIN_CONTENT" > "$CAPTURE_DIR/stdin.txt"

# ---------------------------------------------------------------------------
# Descendant forking (before ready signal)
# ---------------------------------------------------------------------------
DESCENDANT_PID=""
DESCENDANT_PGID=""

if [ "${FAKE_CODEX_FORK_DESCENDANT:-}" = "1" ]; then
    DESCENDANT_SLEEP="${FAKE_CODEX_DESCENDANT_SLEEP_SECS:-60}"
    DESCENDANT_TERM_MODE="${FAKE_CODEX_DESCENDANT_TERM_MODE:-default}"

    (
        # Descendant runs in the same process group (no setsid)
        case "$DESCENDANT_TERM_MODE" in
            clean)
                trap 'exit 0' TERM
                ;;
            ignore)
                trap '' TERM
                ;;
            *)
                # default: no trap, TERM kills immediately
                ;;
        esac
        sleep "$DESCENDANT_SLEEP"
    ) &
    DESCENDANT_PID=$!
    # PGID of descendant should match parent's PGID (same process group)
    DESCENDANT_PGID="$(ps -o pgid= -p $DESCENDANT_PID 2>/dev/null | tr -d ' ' || echo "unknown")"
fi

# ---------------------------------------------------------------------------
# Status JSON
# ---------------------------------------------------------------------------
PARENT_PID=$$
PARENT_PGID="$(ps -o pgid= -p $$ 2>/dev/null | tr -d ' ' || echo "0")"
TERM_MODE="${FAKE_CODEX_TERM_MODE:-default}"

# Build descendant fields as JSON values
if [ -n "${DESCENDANT_PID:-}" ]; then
    DESC_PID_JSON="$DESCENDANT_PID"
    DESC_PGID_JSON="\"${DESCENDANT_PGID:-unknown}\""
else
    DESC_PID_JSON="null"
    DESC_PGID_JSON="null"
fi

cat > "$CAPTURE_DIR/status.json" <<STATUSEOF
{
  "parent_pid": $PARENT_PID,
  "parent_pgid": $PARENT_PGID,
  "descendant_pid": $DESC_PID_JSON,
  "descendant_pgid": $DESC_PGID_JSON,
  "term_mode": "$TERM_MODE",
  "ready_ts": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
STATUSEOF

# ---------------------------------------------------------------------------
# Ready signal — only AFTER all captures and descendant fork
# ---------------------------------------------------------------------------
if [ -n "${FAKE_CODEX_READY_FILE:-}" ]; then
    touch "$FAKE_CODEX_READY_FILE"
fi

# ---------------------------------------------------------------------------
# Signal handling for parent
# ---------------------------------------------------------------------------
case "$TERM_MODE" in
    clean)
        trap 'exit 0' TERM
        ;;
    ignore)
        trap '' TERM
        ;;
    *)
        # default: no trap, TERM kills with signal exit code
        ;;
esac

# ---------------------------------------------------------------------------
# Sleep phase
# ---------------------------------------------------------------------------
SLEEP_SECS="${FAKE_CODEX_SLEEP_SECS:-0}"
if [ "$SLEEP_SECS" != "0" ]; then
    if [ "$TERM_MODE" = "default" ]; then
        # Foreground sleep: SIGTERM kills the sleep process, then bash
        # exits with the signal status (allowing signal capture in tests)
        exec sleep "$SLEEP_SECS"
    else
        # Background sleep + wait: allows signal traps to fire
        sleep "$SLEEP_SECS" &
        SLEEP_PID=$!
        wait $SLEEP_PID 2>/dev/null || true
    fi
fi

# ---------------------------------------------------------------------------
# Output writing
# ---------------------------------------------------------------------------
EXIT_CODE="${FAKE_CODEX_EXIT_CODE:-0}"

# Write HANDOFF.md if requested
if [ "${FAKE_CODEX_WRITE_HANDOFF:-}" = "1" ] && [ -n "$OUTPUT_PATH" ]; then
    RELAY_ROOT="$(dirname "$OUTPUT_PATH")"
    cat > "$RELAY_ROOT/HANDOFF.md" <<'HANDOFFEOF'
# Handoff

### Files Changed
- (fake) none

### Tests Run
- (fake) none

### Verification
- (fake) verified

### Verdict
CLEAN

### Completion Claim
COMPLETE

### Issues Found
None

### Next Steps
None
HANDOFFEOF
fi

# Write last-message if requested and exit is clean
if [ "${FAKE_CODEX_WRITE_LAST_MESSAGE:-}" = "1" ] && [ -n "$OUTPUT_PATH" ] && [ "$EXIT_CODE" = "0" ]; then
    echo "fake codex completed successfully" > "$OUTPUT_PATH"
fi

# ---------------------------------------------------------------------------
# Clean up descendant if still running
# ---------------------------------------------------------------------------
if [ -n "${DESCENDANT_PID:-}" ]; then
    # Don't kill on normal exit — let the adapter's containment logic handle it
    # This is intentional: if the adapter properly kills the process group,
    # the descendant will already be dead
    :
fi

exit "$EXIT_CODE"

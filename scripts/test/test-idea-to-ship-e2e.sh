#!/usr/bin/env bash
# test-idea-to-ship-e2e.sh — End-to-end integration test for the idea-to-ship method.
#
# Validates the full method-runner pipeline in three parts:
#   Part A: Run idea-to-ship with fake adapters + FileInteractiveIO (--response-dir)
#   Part B: Verify compose-prompt.sh works with a temp HOME containing skills/templates
#   Part C: Verify fake-codex.sh standalone contract
#
# Together these three parts validate the complete chain from YAML definition
# through prompt composition, worker dispatch, gate evaluation, and artifact
# verification — without requiring FAKE_CODEX_* env vars to pass through
# the real adapter's env_clear() boundary.
#
# GAP: Full --real mode E2E with fake-codex.sh requires a CLI --env-override
# flag to inject FAKE_CODEX_* vars into the subprocess environment. The real
# adapters use env_clear() + an allowlist, stripping any ambient FAKE_CODEX_*
# vars. Until --env-override is added to the CLI, this three-part approach
# validates each boundary independently.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  echo "  PASS: $1"
}

fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  echo "  FAIL: $1"
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "=== End-to-End: Idea-to-Ship Flow ==="
echo "temp dir: $TMP"
echo ""

# =========================================================================
# Part A: Run idea-to-ship with fake adapters + FileInteractiveIO
# =========================================================================

echo "--- Part A: Fake adapters + FileInteractiveIO ---"

RELAY_ROOT_A="$TMP/part-a"
RESPONSE_DIR_A="$TMP/responses-a"
mkdir -p "$RESPONSE_DIR_A"

# Stage gate response JSON files for interactive gates.
# shape-gate: approval type — needs "approved" action
# review-gate: approval type — needs "approved" action
# build-gate: handoff_verdict — auto-evaluated from handoff content, not interactive
# ship-gate: completion_claim — auto-evaluated from handoff content, not interactive
echo '{"action": "approved", "note": "Shape looks good"}' > "$RESPONSE_DIR_A/shape-gate.json"
echo '{"action": "approved", "note": "Implementation approved"}' > "$RESPONSE_DIR_A/review-gate.json"

echo "  Running idea-to-ship method (fake adapters)..."
if cargo run -p capacitor-core --bin method-runner -- run \
  --definition "$REPO_ROOT/methods/fixtures/idea-to-ship.yaml" \
  --root "$RELAY_ROOT_A" \
  --response-dir "$RESPONSE_DIR_A" 2>&1; then
  pass "method-runner run completed successfully"
else
  fail "method-runner run failed"
  echo "  Aborting Part A — cannot verify artifacts without a successful run."
  echo ""
  # Continue to Part B/C even if Part A fails
fi

# A1: Events file exists
if [ -f "$RELAY_ROOT_A/.method/events.ndjson" ]; then
  pass "events.ndjson exists"
else
  fail "events.ndjson missing"
fi

# A2: State file exists
if [ -f "$RELAY_ROOT_A/.method/state.json" ]; then
  pass "state.json exists"
else
  fail "state.json missing"
fi

# A3: Check state shows completed
if [ -f "$RELAY_ROOT_A/.method/state.json" ]; then
  STATUS=$(python3 -c "import json,sys; print(json.load(sys.stdin)['status'])" < "$RELAY_ROOT_A/.method/state.json" 2>/dev/null || echo "unknown")
  if [ "$STATUS" = "completed" ]; then
    pass "run status is 'completed'"
  else
    fail "expected status 'completed', got '$STATUS'"
  fi
fi

# A4: gate_evaluated events present
if [ -f "$RELAY_ROOT_A/.method/events.ndjson" ]; then
  if grep -q '"gate_evaluated"' "$RELAY_ROOT_A/.method/events.ndjson" 2>/dev/null; then
    pass "gate_evaluated events present"
  else
    fail "no gate_evaluated events found"
  fi
fi

# A5: All 4 phase_completed events (shape, build, review, ship)
if [ -f "$RELAY_ROOT_A/.method/events.ndjson" ]; then
  PHASE_COUNT=$(grep -c '"phase_completed"' "$RELAY_ROOT_A/.method/events.ndjson" || true)
  if [ "$PHASE_COUNT" -ge 4 ]; then
    pass "all 4 phase_completed events present (found $PHASE_COUNT)"
  else
    fail "expected 4+ phase_completed events, got $PHASE_COUNT"
  fi
fi

# A6: All 4 gate_evaluated events (one per phase gate)
if [ -f "$RELAY_ROOT_A/.method/events.ndjson" ]; then
  GATE_COUNT=$(grep -c '"gate_evaluated"' "$RELAY_ROOT_A/.method/events.ndjson" || true)
  if [ "$GATE_COUNT" -ge 4 ]; then
    pass "all 4 gate_evaluated events present (found $GATE_COUNT)"
  else
    fail "expected 4+ gate_evaluated events, got $GATE_COUNT"
  fi
fi

# A7: Definition snapshot was persisted
if [ -f "$RELAY_ROOT_A/.method/definition.snapshot.yaml" ]; then
  pass "definition.snapshot.yaml persisted"
else
  fail "definition.snapshot.yaml missing"
fi

# A8: Run lock was released (lock file should not exist after clean completion)
if [ -f "$RELAY_ROOT_A/.method/locks/run.lock" ]; then
  fail "run.lock still held after completion"
else
  pass "run.lock released after completion"
fi

echo ""

# =========================================================================
# Part B: Verify compose-prompt.sh with temp HOME
# =========================================================================

echo "--- Part B: compose-prompt.sh with temp HOME ---"

FAKE_HOME="$TMP/fake-home"
SKILL_DIR="$FAKE_HOME/.claude/skills"
MANAGE_CODEX_DIR="$SKILL_DIR/manage-codex/references"
mkdir -p "$SKILL_DIR/base-skill"
mkdir -p "$SKILL_DIR/build-skill"
mkdir -p "$SKILL_DIR/implement-skill"
mkdir -p "$MANAGE_CODEX_DIR"

# Create dummy skill files (referenced by idea-to-ship.yaml)
echo "# Base Skill" > "$SKILL_DIR/base-skill/SKILL.md"
echo "Base domain guidance for all phases." >> "$SKILL_DIR/base-skill/SKILL.md"

echo "# Build Skill" > "$SKILL_DIR/build-skill/SKILL.md"
echo "Build-phase domain guidance." >> "$SKILL_DIR/build-skill/SKILL.md"

echo "# Implement Skill" > "$SKILL_DIR/implement-skill/SKILL.md"
echo "Implementation worker guidance." >> "$SKILL_DIR/implement-skill/SKILL.md"

# Create dummy template file (idea-to-ship uses template: implement)
cat > "$MANAGE_CODEX_DIR/implement-template.md" <<'TMPL'
# Implementation Template

## Objective
Build the feature as specified.

### Files Changed
- (pending)

### Tests Run
- (pending)

### Verification
- (pending)

### Verdict
PENDING

### Completion Claim
PENDING

### Issues Found
None

### Next Steps
None
TMPL

# Create a test header file
PROMPT_DIR="$TMP/part-b-prompt"
mkdir -p "$PROMPT_DIR"
cat > "$PROMPT_DIR/header.md" <<'HEADER'
# Step: implement
Phase: build
Attempt: 1

Implement the feature based on shaped requirements.
HEADER

# B1: compose-prompt.sh with skills
echo "  Testing compose-prompt.sh with skills..."
if HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/relay/compose-prompt.sh" \
  --header "$PROMPT_DIR/header.md" \
  --skills "base-skill,build-skill" \
  --out "$PROMPT_DIR/out-skills.md" 2>&1; then
  if [ -f "$PROMPT_DIR/out-skills.md" ]; then
    pass "compose-prompt.sh produced output with skills"
    # Verify skills were included
    if grep -q "Base Skill" "$PROMPT_DIR/out-skills.md" && \
       grep -q "Build Skill" "$PROMPT_DIR/out-skills.md"; then
      pass "skill content included in composed prompt"
    else
      fail "skill content not found in composed prompt"
    fi
  else
    fail "compose-prompt.sh did not produce output file"
  fi
else
  fail "compose-prompt.sh failed with skills"
fi

# B2: compose-prompt.sh with template
echo "  Testing compose-prompt.sh with template..."
if HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/relay/compose-prompt.sh" \
  --header "$PROMPT_DIR/header.md" \
  --skills "base-skill,build-skill,implement-skill" \
  --template "implement" \
  --out "$PROMPT_DIR/out-template.md" 2>&1; then
  if [ -f "$PROMPT_DIR/out-template.md" ]; then
    pass "compose-prompt.sh produced output with template"
    # Verify template was included
    if grep -q "Implementation Template" "$PROMPT_DIR/out-template.md"; then
      pass "template content included in composed prompt"
    else
      fail "template content not found in composed prompt"
    fi
  else
    fail "compose-prompt.sh did not produce template output file"
  fi
else
  fail "compose-prompt.sh failed with template"
fi

# B3: compose-prompt.sh with --root for relay_root substitution
echo "  Testing compose-prompt.sh with --root substitution..."
cat > "$PROMPT_DIR/header-with-token.md" <<'TOKENHEADER'
# Step: implement
Relay root: {relay_root}
TOKENHEADER

if HOME="$FAKE_HOME" bash "$REPO_ROOT/scripts/relay/compose-prompt.sh" \
  --header "$PROMPT_DIR/header-with-token.md" \
  --root "/tmp/test-relay" \
  --out "$PROMPT_DIR/out-root.md" 2>&1; then
  if [ -f "$PROMPT_DIR/out-root.md" ]; then
    if grep -q "/tmp/test-relay" "$PROMPT_DIR/out-root.md" && \
       ! grep -q '{relay_root}' "$PROMPT_DIR/out-root.md"; then
      pass "relay_root token substituted correctly"
    else
      fail "relay_root token not substituted"
    fi
  else
    fail "compose-prompt.sh did not produce root-subst output"
  fi
else
  fail "compose-prompt.sh failed with --root"
fi

echo ""

# =========================================================================
# Part C: Verify fake-codex.sh standalone
# =========================================================================

echo "--- Part C: fake-codex.sh standalone contract ---"

CAPTURE_DIR_C="$TMP/part-c-capture"
RELAY_DIR_C="$TMP/part-c-relay"
mkdir -p "$CAPTURE_DIR_C" "$RELAY_DIR_C"

FAKE_CODEX="$REPO_ROOT/scripts/test/fake-codex.sh"

# C1: Basic exec with exit 0 + captures
echo "  Testing fake-codex.sh basic exec..."
if FAKE_CODEX_CAPTURE_DIR="$CAPTURE_DIR_C/basic" \
   FAKE_CODEX_EXIT_CODE=0 \
   FAKE_CODEX_WRITE_LAST_MESSAGE=1 \
   bash "$FAKE_CODEX" exec --full-auto -o "$RELAY_DIR_C/last-message.txt" - < /dev/null 2>&1; then
  pass "fake-codex.sh exited 0"
else
  fail "fake-codex.sh exited non-zero"
fi

if [ -f "$CAPTURE_DIR_C/basic/argv.txt" ]; then
  pass "argv capture exists"
else
  fail "argv capture missing"
fi

if [ -f "$CAPTURE_DIR_C/basic/env.txt" ]; then
  pass "env capture exists"
else
  fail "env capture missing"
fi

if [ -f "$CAPTURE_DIR_C/basic/status.json" ]; then
  pass "status.json capture exists"
else
  fail "status.json capture missing"
fi

if [ -f "$RELAY_DIR_C/last-message.txt" ]; then
  pass "last-message.txt written"
else
  fail "last-message.txt not written"
fi

# C2: HANDOFF.md writing
echo "  Testing fake-codex.sh HANDOFF.md generation..."
CAPTURE_DIR_C2="$CAPTURE_DIR_C/handoff"
RELAY_DIR_C2="$TMP/part-c-relay-handoff"
mkdir -p "$RELAY_DIR_C2"

if FAKE_CODEX_CAPTURE_DIR="$CAPTURE_DIR_C2" \
   FAKE_CODEX_EXIT_CODE=0 \
   FAKE_CODEX_WRITE_HANDOFF=1 \
   FAKE_CODEX_WRITE_LAST_MESSAGE=1 \
   bash "$FAKE_CODEX" exec --full-auto -o "$RELAY_DIR_C2/last-message.txt" - < /dev/null 2>&1; then

  if [ -f "$RELAY_DIR_C2/HANDOFF.md" ]; then
    pass "HANDOFF.md written"
    # Verify canonical handoff headings
    if grep -q "### Verdict" "$RELAY_DIR_C2/HANDOFF.md" && \
       grep -q "CLEAN" "$RELAY_DIR_C2/HANDOFF.md" && \
       grep -q "### Completion Claim" "$RELAY_DIR_C2/HANDOFF.md" && \
       grep -q "COMPLETE" "$RELAY_DIR_C2/HANDOFF.md"; then
      pass "HANDOFF.md has CLEAN verdict and COMPLETE claim"
    else
      fail "HANDOFF.md missing expected headings/values"
    fi
  else
    fail "HANDOFF.md not written"
  fi
else
  fail "fake-codex.sh failed during handoff test"
fi

# C3: Non-zero exit code
echo "  Testing fake-codex.sh non-zero exit..."
CAPTURE_DIR_C3="$CAPTURE_DIR_C/exit1"
if FAKE_CODEX_CAPTURE_DIR="$CAPTURE_DIR_C3" \
   FAKE_CODEX_EXIT_CODE=1 \
   bash "$FAKE_CODEX" exec --full-auto -o /dev/null - < /dev/null 2>&1; then
  fail "fake-codex.sh should have exited non-zero"
else
  pass "fake-codex.sh exited non-zero as configured"
fi

# C4: Stdin capture
echo "  Testing fake-codex.sh stdin capture..."
CAPTURE_DIR_C4="$CAPTURE_DIR_C/stdin"
echo "test prompt content" | \
  FAKE_CODEX_CAPTURE_DIR="$CAPTURE_DIR_C4" \
  FAKE_CODEX_EXIT_CODE=0 \
  bash "$FAKE_CODEX" exec --full-auto -o /dev/null - 2>&1

if [ -f "$CAPTURE_DIR_C4/stdin.txt" ]; then
  STDIN_CONTENT=$(cat "$CAPTURE_DIR_C4/stdin.txt")
  if [ "$STDIN_CONTENT" = "test prompt content" ]; then
    pass "stdin captured correctly"
  else
    fail "stdin content mismatch: got '$STDIN_CONTENT'"
  fi
else
  fail "stdin.txt not captured"
fi

echo ""

# =========================================================================
# Summary
# =========================================================================

echo "==========================================="
echo "  Results: $PASS_COUNT passed, $FAIL_COUNT failed"
echo "==========================================="

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo ""
  echo "SOME CHECKS FAILED"
  exit 1
fi

echo ""
echo "=== ALL E2E CHECKS PASSED ==="

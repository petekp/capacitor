#!/usr/bin/env bash
# dispatch.sh — Backend-agnostic dispatch for Circuit workers
#
# Detects whether Codex CLI is available and dispatches accordingly.
# When Codex is installed, uses `codex exec --full-auto`.
# When Codex is not installed, emits an Agent tool invocation that the
# orchestrator (Claude) should execute directly.
#
# Usage:
#   ./scripts/relay/dispatch.sh --prompt <file> --output <file> [--backend codex|agent]
#
# Options:
#   --prompt FILE    — Assembled prompt file to send to the worker (required)
#   --output FILE    — Path where worker should write its last-message trace (required)
#   --backend MODE   — Force dispatch engine (optional; auto-detects if omitted)
#
#   Built-in engines:
#     codex   — Codex CLI (`codex exec --full-auto`)
#     agent   — Claude Code Agent tool (isolation: "worktree")
#
#   Custom engines:
#     Any other value is treated as a shell command. The prompt file is passed
#     as $1 and the expected output path as $2. Example:
#       --backend "gemini run"
#       --backend "claude -p"
#       --backend "./my-agent.sh"
#
# Exit codes:
#   0  — Dispatch succeeded (codex/custom) or instructions emitted (agent)
#   1  — Error (missing args, command not found, etc.)
#
# When backend=agent, this script does NOT execute the Agent tool itself (it cannot —
# that's a Claude Code tool). Instead it prints a structured instruction block that
# the orchestrator should copy into an Agent tool call.

set -euo pipefail

PROMPT=""
OUTPUT=""
BACKEND=""
CIRCUIT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prompt)  PROMPT="$2"; shift 2 ;;
    --output)  OUTPUT="$2"; shift 2 ;;
    --backend) BACKEND="$2"; shift 2 ;;
    --circuit) CIRCUIT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PROMPT" || -z "$OUTPUT" ]]; then
  echo "ERROR: --prompt and --output are required" >&2
  exit 1
fi

if [[ ! -f "$PROMPT" ]]; then
  echo "ERROR: prompt file not found: $PROMPT" >&2
  exit 1
fi

# Resolve dispatch engine: explicit flag > config per-circuit > config global > auto-detect
if [[ -z "$BACKEND" ]]; then
  # Check circuit.config.yaml for dispatch.per_circuit.<id> or dispatch.engine
  for config_path in ./circuit.config.yaml ~/.claude/circuit.config.yaml; do
    if [[ -f "$config_path" ]]; then
      if [[ -n "$CIRCUIT" ]]; then
        per_circuit="$(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('$config_path'))
    print(cfg.get('dispatch',{}).get('per_circuit',{}).get('$CIRCUIT',''))
except: pass
" 2>/dev/null)"
        [[ -n "$per_circuit" ]] && BACKEND="$per_circuit" && break
      fi
      global_engine="$(python3 -c "
import yaml, sys
try:
    cfg = yaml.safe_load(open('$config_path'))
    print(cfg.get('dispatch',{}).get('engine',''))
except: pass
" 2>/dev/null)"
      [[ -n "$global_engine" && "$global_engine" != "auto" ]] && BACKEND="$global_engine" && break
    fi
  done
fi

# Fall back to auto-detection
if [[ -z "$BACKEND" ]]; then
  if command -v codex >/dev/null 2>&1; then
    BACKEND="codex"
  else
    BACKEND="agent"
  fi
fi

case "$BACKEND" in
  codex)
    if ! command -v codex >/dev/null 2>&1; then
      echo "ERROR: --backend codex specified but codex CLI not found" >&2
      echo "Install with: npm install -g @openai/codex" >&2
      exit 1
    fi
    cat "$PROMPT" | codex exec --full-auto -o "$OUTPUT" -
    ;;

  agent)
    # Emit structured instructions for the orchestrator to use the Agent tool.
    # The orchestrator (Claude) reads this output and creates an Agent tool call.
    PROMPT_CONTENT="$(cat "$PROMPT")"
    cat <<AGENT_INSTRUCTIONS
DISPATCH_BACKEND=agent

Use the Agent tool to execute this worker. Pass the prompt content below as the
Agent tool's task parameter. Use isolation: "worktree" for safe execution.

Agent tool parameters:
  task: |
    ${PROMPT_CONTENT}

    ---
    Write your last-message trace to: ${OUTPUT}
  isolation: worktree

After the Agent completes, verify its output artifacts exist at the expected paths.
AGENT_INSTRUCTIONS
    ;;

  *)
    # Treat any other value as a custom command.
    # The command receives the prompt file as $1 and output path as $2.
    CMD_NAME="${BACKEND%% *}"
    if ! command -v "$CMD_NAME" >/dev/null 2>&1 && [[ ! -x "$CMD_NAME" ]]; then
      echo "ERROR: custom dispatch engine not found: $CMD_NAME" >&2
      echo "Ensure the command exists and is executable." >&2
      exit 1
    fi
    $BACKEND "$PROMPT" "$OUTPUT"
    ;;
esac

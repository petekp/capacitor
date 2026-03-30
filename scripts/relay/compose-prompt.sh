#!/usr/bin/env bash
# compose-prompt.sh — Assemble a worker prompt from header + skills + template
#
# Usage:
#   ./scripts/relay/compose-prompt.sh --header .relay/prompt-header.md --skills swift-apps,rust --out .relay/prompt.md
#   ./scripts/relay/compose-prompt.sh --header .relay/review-header.md --template review --out .relay/review-prompt.md
#   ./scripts/relay/compose-prompt.sh --header .relay/prompt-header.md --template implement --root /tmp/relay-root --out .relay/prompt.md
#   ./scripts/relay/compose-prompt.sh --header .relay/prompt-header.md --backend agent --out .relay/prompt.md
#
# Options:
#   --header FILE    — Task-specific header (required)
#   --skills LIST    — Comma-separated domain skill names (optional)
#   --circuit ID     — Circuit id for config-file skill lookup (optional, used when --skills is omitted)
#   --config FILE    — Path to circuit.config.yaml (optional, auto-discovered from ./circuit.config.yaml or ~/.claude/circuit.config.yaml)
#   --template NAME  — Template to append: implement, review, ship-review, converge (optional)
#   --root DIR       — Substitute literal {relay_root} tokens after assembly (optional unless placeholders are used)
#   --backend MODE   — Dispatch backend hint: "codex" or "agent" (optional; auto-detected if omitted)
#   --out FILE       — Output path (required)

set -euo pipefail

HEADER=""
SKILLS=""
CIRCUIT=""
CONFIG=""
TEMPLATE=""
ROOT=""
BACKEND=""
OUT=""

# Resolve SKILL_DIR: env var > sibling skills/ dir > ~/.claude/skills
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [[ -n "${CIRCUIT_PLUGIN_SKILL_DIR:-}" ]]; then
  SKILL_DIR="$CIRCUIT_PLUGIN_SKILL_DIR"
elif [[ -d "$PLUGIN_ROOT/skills" ]]; then
  SKILL_DIR="$PLUGIN_ROOT/skills"
else
  SKILL_DIR="$HOME/.claude/skills"
fi

# Resolve MANAGE_CODEX_DIR: env var > script-local references/ dir >
# plugin-relative references/ dir > ~/.claude/skills
if [[ -n "${CIRCUIT_PLUGIN_CODEX_DIR:-}" ]]; then
  MANAGE_CODEX_DIR="$CIRCUIT_PLUGIN_CODEX_DIR"
elif [[ -d "$SCRIPT_DIR/references" ]]; then
  MANAGE_CODEX_DIR="$SCRIPT_DIR/references"
elif [[ -d "$PLUGIN_ROOT/skills/manage-codex/references" ]]; then
  MANAGE_CODEX_DIR="$PLUGIN_ROOT/skills/manage-codex/references"
else
  MANAGE_CODEX_DIR="$HOME/.claude/skills/manage-codex/references"
fi

RELAY_ROOT_SOURCES=()

track_relay_root_source() {
  local source_file="$1"
  local existing_source

  if [[ ! -f "$source_file" ]] || ! grep -Fq '{relay_root}' "$source_file"; then
    return 0
  fi

  if (( ${#RELAY_ROOT_SOURCES[@]} > 0 )); then
    for existing_source in "${RELAY_ROOT_SOURCES[@]}"; do
      if [[ "$existing_source" == "$source_file" ]]; then
        return 0
      fi
    done
  fi

  RELAY_ROOT_SOURCES+=("$source_file")
}

apply_relay_root_substitution() {
  local out_file="$1"
  local relay_root="$2"
  local escaped_root
  local temp_file

  escaped_root="$(printf '%s' "$relay_root" | sed 's/[&|\\]/\\&/g')"
  temp_file="$(mktemp "${TMPDIR:-/tmp}/compose-prompt.XXXXXX")"

  sed "s|{relay_root}|$escaped_root|g" "$out_file" > "$temp_file"
  mv "$temp_file" "$out_file"
}

fail_if_unresolved_relay_root() {
  local out_file="$1"
  local source_file
  local source_names=()
  local source_summary

  if ! grep -Fq '{relay_root}' "$out_file"; then
    return 0
  fi

  if (( ${#RELAY_ROOT_SOURCES[@]} > 0 )); then
    for source_file in "${RELAY_ROOT_SOURCES[@]}"; do
      # Use parent/basename for skills (e.g., "demo/SKILL.md"), basename for others
      local parent_dir
      parent_dir="$(basename "$(dirname "$source_file")")"
      local base
      base="$(basename "$source_file")"
      if [[ "$base" == "SKILL.md" ]]; then
        source_names+=("$parent_dir/$base")
      else
        source_names+=("$base")
      fi
    done
  fi

  if [[ ${#source_names[@]} -gt 0 ]]; then
    local IFS=', '
    source_summary="${source_names[*]}"
  else
    source_summary="unknown source"
  fi

  echo "ERROR: unresolved {relay_root} token(s) remain in $out_file; introduced by: $source_summary" >&2
  exit 1
}

append_section_file() {
  local out_file="$1"
  local section_file="$2"

  if [[ -f "$section_file" ]]; then
    track_relay_root_source "$section_file"
    printf '\n---\n' >> "$out_file"
    cat "$section_file" >> "$out_file"
  else
    echo "WARNING: file not found: $section_file" >&2
  fi
}

output_has_inline_relay() {
  local out_file="$1"

  grep -q '^### Files Changed$' "$out_file" &&
    grep -q '^### Tests Run$' "$out_file" &&
    grep -q '^### Completion Claim$' "$out_file"
}

is_blank_arg() {
  local value="$1"

  [[ -z "${value//[[:space:]]/}" ]]
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --header)   HEADER="$2"; shift 2 ;;
    --skills)   SKILLS="$2"; shift 2 ;;
    --circuit)  CIRCUIT="$2"; shift 2 ;;
    --config)   CONFIG="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --root)     ROOT="$2"; shift 2 ;;
    --backend)  BACKEND="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$HEADER" || -z "$OUT" ]]; then
  echo "ERROR: --header and --out are required" >&2
  exit 1
fi

if is_blank_arg "$HEADER"; then
  echo "ERROR: --header must be a non-empty, non-whitespace string" >&2
  exit 1
fi

if is_blank_arg "$OUT"; then
  echo "ERROR: --out must be a non-empty, non-whitespace string" >&2
  exit 1
fi

if [[ ! -f "$HEADER" ]]; then
  echo "ERROR: header file not found: $HEADER" >&2
  exit 1
fi

# Resolve skills from config file when --skills is not provided but --circuit is
if [[ -z "$SKILLS" && -n "$CIRCUIT" ]]; then
  # Auto-discover config file if --config not specified
  if [[ -z "$CONFIG" ]]; then
    if [[ -f "./circuit.config.yaml" ]]; then
      CONFIG="./circuit.config.yaml"
    elif [[ -f "$HOME/.claude/circuit.config.yaml" ]]; then
      CONFIG="$HOME/.claude/circuit.config.yaml"
    fi
  fi

  # Read skills from config if available
  if [[ -n "$CONFIG" && -f "$CONFIG" ]]; then
    # Extract skills for the given circuit id using basic YAML parsing
    # Supports format: circuits.<id>.skills: [skill1, skill2]
    # or: circuits.<id>.skills:\n  - skill1\n  - skill2
    CONFIG_SKILLS="$(python3 -c "
import yaml, sys
try:
    with open('$CONFIG') as f:
        cfg = yaml.safe_load(f)
    circuits = cfg.get('circuits', {})
    entry = circuits.get('$CIRCUIT', {})
    skills = entry.get('skills', [])
    if isinstance(skills, list):
        print(','.join(str(s) for s in skills))
" 2>/dev/null || true)"
    if [[ -n "$CONFIG_SKILLS" ]]; then
      SKILLS="$CONFIG_SKILLS"
    fi
  fi
fi

# Start with header
track_relay_root_source "$HEADER"
cp "$HEADER" "$OUT"

# Append domain skills
if [[ -n "$SKILLS" ]]; then
  IFS=',' read -ra SKILL_ARRAY <<< "$SKILLS"
  for skill in "${SKILL_ARRAY[@]}"; do
    skill_file="$SKILL_DIR/$skill/SKILL.md"
    if [[ -f "$skill_file" ]]; then
      track_relay_root_source "$skill_file"
      printf '\n---\n## Domain Guidance: %s\n\n' "$skill" >> "$OUT"
      cat "$skill_file" >> "$OUT"
    else
      echo "WARNING: skill not found: $skill_file" >&2
    fi
  done
fi

# Append template
if [[ -n "$TEMPLATE" ]]; then
  if [[ "$TEMPLATE" == "review" || "$TEMPLATE" == "ship-review" || "$TEMPLATE" == "converge" ]]; then
    preamble_file="$MANAGE_CODEX_DIR/review-preamble.md"
    if [[ -f "$preamble_file" ]]; then
      append_section_file "$OUT" "$preamble_file"
    fi
  fi

  template_file="$MANAGE_CODEX_DIR/${TEMPLATE}-template.md"
  append_section_file "$OUT" "$template_file"
fi

# Legacy fallback: older templates rely on a separately appended relay protocol.
protocol_file="$MANAGE_CODEX_DIR/relay-protocol.md"
if ! output_has_inline_relay "$OUT" && [[ -f "$protocol_file" ]]; then
  append_section_file "$OUT" "$protocol_file"
fi

if [[ -n "$ROOT" ]]; then
  apply_relay_root_substitution "$OUT" "$ROOT"
fi

fail_if_unresolved_relay_root "$OUT"

# Auto-detect backend if not specified
if [[ -z "$BACKEND" ]]; then
  if command -v codex >/dev/null 2>&1; then
    BACKEND="codex"
  else
    BACKEND="agent"
  fi
fi

# Emit backend hint as a metadata comment at the end of the composed prompt
printf '\n<!-- dispatch-backend: %s -->\n' "$BACKEND" >> "$OUT"

echo "Composed: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines, backend=$BACKEND)"

#!/usr/bin/env bash
# compose-prompt.sh — Assemble a Codex worker prompt from header + skills + template
#
# Usage:
#   ./scripts/relay/compose-prompt.sh --header .relay/prompt-header.md --skills swift-apps,rust --out .relay/prompt.md
#   ./scripts/relay/compose-prompt.sh --header .relay/review-header.md --template review --out .relay/review-prompt.md
#
# Options:
#   --header FILE    — Task-specific header (required)
#   --skills LIST    — Comma-separated domain skill names (optional)
#   --template NAME  — Template to append: implement, review, ship-review, converge (optional)
#   --out FILE       — Output path (required)

set -euo pipefail

HEADER=""
SKILLS=""
TEMPLATE=""
OUT=""
SKILL_DIR="$HOME/.claude/skills"
MANAGE_CODEX_DIR="$HOME/.claude/skills/manage-codex/references"

append_section_file() {
  local out_file="$1"
  local section_file="$2"

  if [[ -f "$section_file" ]]; then
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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --header)   HEADER="$2"; shift 2 ;;
    --skills)   SKILLS="$2"; shift 2 ;;
    --template) TEMPLATE="$2"; shift 2 ;;
    --out)      OUT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$HEADER" || -z "$OUT" ]]; then
  echo "ERROR: --header and --out are required" >&2
  exit 1
fi

if [[ ! -f "$HEADER" ]]; then
  echo "ERROR: header file not found: $HEADER" >&2
  exit 1
fi

# Start with header
cp "$HEADER" "$OUT"

# Append domain skills
if [[ -n "$SKILLS" ]]; then
  IFS=',' read -ra SKILL_ARRAY <<< "$SKILLS"
  for skill in "${SKILL_ARRAY[@]}"; do
    skill_file="$SKILL_DIR/$skill/SKILL.md"
    if [[ -f "$skill_file" ]]; then
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

echo "Composed: $OUT ($(wc -l < "$OUT" | tr -d ' ') lines)"

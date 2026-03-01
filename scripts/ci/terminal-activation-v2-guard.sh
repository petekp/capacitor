#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-check}"
if [[ "$MODE" != "check" && "$MODE" != "--status" ]]; then
  echo "Usage: $0 [check|--status]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SLICES_FILE="$ROOT/.claude/migration/terminal-activation-v2/SLICES.yaml"

failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

# ── Ratchet Budgets ──────────────────────────────────────────────
# Each budget is the maximum allowed count of a legacy pattern.
# Start at measured baseline, decrement as slices eliminate instances.
# Target: all reach 0 by TAv2-006.

BUDGET_RESOLVE_ATTACHED_TTY=0     # resolveAttachedTmuxClientTty in Sources (TAv2-006: renamed to resolveAnyTmuxClientTty)
BUDGET_ACTION_SPECIFIC_METHODS=0  # performSwitch|performEnsure|switchTmuxSessionAction|ensureTmuxSessionAction|launchTerminalWithAERSnapshot in Sources (TAv2-006: all deleted)
BUDGET_EXECUTOR_REFS=0            # ActivationActionExecutor in Sources (TAv2-006: file deleted)
BUDGET_ACTION_TEST_METHODS=0      # action-specific methods in Tests (TAv2-006: all deleted)

check_ratchet() {
  local label="$1"
  local budget="$2"
  local pattern="$3"
  local search_path="$4"

  local count
  count=$(cd "$ROOT" && { rg -c "$pattern" "$search_path" 2>/dev/null || true; } | awk -F: '{s+=$NF} END {print s+0}')

  if [[ "$MODE" == "--status" ]]; then
    printf "  %-40s %3d / %3d\n" "$label" "$count" "$budget"
    return
  fi

  if (( count > budget )); then
    fail "Ratchet '$label' exceeded budget: count=$count budget=$budget"
  fi
}

if [[ "$MODE" == "--status" ]]; then
  echo "Terminal Activation v2 Guard Status"
  echo ""

  if [[ -f "$SLICES_FILE" ]]; then
    ruby -ryaml -e '
      data = YAML.load_file(ARGV[0]) || {}
      slices = data.fetch("slices", [])
      counts = slices.group_by { |s| s["status"].to_s }
      puts "  Slices: #{slices.length} total"
      puts "    pending:     #{counts.fetch("pending", []).length}"
      puts "    in_progress: #{counts.fetch("in_progress", []).length}"
      puts "    done:        #{counts.fetch("done", []).length}"
      ip = slices.select { |s| s["status"] == "in_progress" }.map { |s| s["id"] }
      puts "    active:      #{ip.empty? ? "none" : ip.join(", ")}"
    ' "$SLICES_FILE"
  else
    echo "  Slices file not found: $SLICES_FILE"
  fi

  echo ""
  echo "  Ratchet Budgets (count / budget):"
fi

check_ratchet \
  "resolveAttachedTmuxClientTty" \
  "$BUDGET_RESOLVE_ATTACHED_TTY" \
  "resolveAttachedTmuxClientTty" \
  "apps/swift/Sources/"

check_ratchet \
  "action-specific methods (Sources)" \
  "$BUDGET_ACTION_SPECIFIC_METHODS" \
  "performSwitchTmuxSession|performEnsureTmuxSession|switchTmuxSessionAction|ensureTmuxSessionAction|launchTerminalWithAERSnapshot" \
  "apps/swift/Sources/"

check_ratchet \
  "ActivationActionExecutor refs" \
  "$BUDGET_EXECUTOR_REFS" \
  "ActivationActionExecutor" \
  "apps/swift/Sources/"

check_ratchet \
  "action-specific methods (Tests)" \
  "$BUDGET_ACTION_TEST_METHODS" \
  "performSwitchTmuxSession|performEnsureTmuxSession|switchTmuxSessionAction|ensureTmuxSessionAction|launchTerminalWithAERSnapshot" \
  "apps/swift/Tests/"

if [[ "$MODE" == "--status" ]]; then
  echo ""
fi

# ── Denylist Enforcement ─────────────────────────────────────────
# Enforce denylist patterns for in_progress and done slices.
if [[ -f "$SLICES_FILE" ]]; then
  while IFS=$'\t' read -r slice_id pattern; do
    [[ -z "$slice_id" || -z "$pattern" ]] && continue

    if [[ "$pattern" == content:* ]]; then
      content_rule="${pattern#content:}"
      if [[ "$content_rule" != *"::"* ]]; then
        fail "Invalid content denylist in $slice_id: '$pattern'"
        continue
      fi

      file_glob="${content_rule%%::*}"
      regex="${content_rule#*::}"
      [[ -z "$file_glob" || -z "$regex" ]] && continue

      matched_files=()
      while IFS= read -r match; do
        [[ -z "$match" ]] && continue
        matched_files+=("$match")
      done < <(cd "$ROOT" && compgen -G "$file_glob" || true)

      (( ${#matched_files[@]} == 0 )) && continue

      content_matches="$(cd "$ROOT" && rg -n --color never -e "$regex" "${matched_files[@]}" || true)"
      if [[ -n "$content_matches" ]]; then
        fail "Denylist violation in $slice_id: '$pattern'"
        echo "$content_matches" | head -n 5 | sed 's/^/  - /'
      fi
    fi
  done < <(
    ruby -ryaml -e '
      data = YAML.load_file(ARGV[0]) || {}
      data.fetch("slices", []).each do |s|
        next unless ["in_progress", "done"].include?(s["status"].to_s)
        Array(s["denylist_patterns"]).each do |p|
          p = p.to_s.strip
          next if p.empty?
          puts "#{s["id"]}\t#{p}"
        end
      end
    ' "$SLICES_FILE"
  )
fi

if (( failures > 0 )); then
  echo "Terminal activation v2 guard failed with $failures error(s)."
  exit 1
fi

echo "Terminal activation v2 guard passed."

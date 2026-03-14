#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"
PLAN_DIR="$ROOT/docs/plans/rust-swift-boundary-legibility"
MAP_FILE="$PLAN_DIR/MAP.csv"
RATCHETS_FILE="$PLAN_DIR/RATCHETS.yaml"
SLICES_FILE="$PLAN_DIR/SLICES.yaml"

STATUS_MODE=false
if [ "${1:-}" = "--status" ]; then
  STATUS_MODE=true
fi

ERRORS=0

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

record_failure() {
  local message="$1"
  if [ "$STATUS_MODE" = true ]; then
    echo "WARN: $message"
  else
    echo "FAIL: $message"
    ERRORS=$((ERRORS + 1))
  fi
}

check_required_files() {
  local required=(
    "$PLAN_DIR/CHARTER.md"
    "$PLAN_DIR/DECISIONS.md"
    "$PLAN_DIR/SLICES.yaml"
    "$PLAN_DIR/MAP.csv"
    "$PLAN_DIR/RATCHETS.yaml"
    "$PLAN_DIR/SHIP_CHECKLIST.md"
    "$PLAN_DIR/TRANSLATION_GUIDE.md"
    "$PLAN_DIR/HANDOFF.md"
    "$PLAN_DIR/guard.sh"
  )

  for path in "${required[@]}"; do
    if [ -e "$path" ]; then
      echo "OK:   control plane file present -> ${path#$ROOT/}"
    else
      record_failure "missing control plane artifact ${path#$ROOT/}"
    fi
  done
}

check_map_paths() {
  local paths
  paths="$(ruby -rcsv -e '
    CSV.foreach(ARGV[0], headers: true) do |row|
      path = row["current_path"].to_s.strip
      next if path.empty? || path == "(new)" || path == "(deleted)"
      puts path
    end
  ' "$MAP_FILE")"

  while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ -e "$ROOT/$path" ]; then
      echo "OK:   mapped path exists -> $path"
    else
      record_failure "mapped current_path missing -> $path"
    fi
  done <<< "$paths"
}

count_matches() {
  local pattern="$1"
  shift
  if [ "$#" -eq 0 ]; then
    echo "0"
    return
  fi

  local count
  count="$( (rg -o --pcre2 --hidden --no-messages "$pattern" "$@" || true) | wc -l | tr -d ' ' )"
  printf '%s' "${count:-0}"
}

check_ratchets() {
  local rows
  rows="$(ruby -ryaml -e '
    data = YAML.load_file(ARGV[0]) || {}
    Array(data["ratchets"]).each do |ratchet|
      fields = [
        ratchet["id"],
        ratchet["label"],
        ratchet["pattern"],
        ratchet["scope"],
        ratchet["budget"],
      ]
      puts fields.map { |value| value.to_s.gsub("\t", " ") }.join("\t")
    end
  ' "$RATCHETS_FILE")"

  while IFS=$'\t' read -r id label pattern scope budget; do
    [ -z "$id" ] && continue

    IFS=',' read -r -a raw_scopes <<< "$scope"
    local scopes=()
    local raw trimmed
    for raw in "${raw_scopes[@]}"; do
      trimmed="$(trim "$raw")"
      [ -z "$trimmed" ] && continue
      scopes+=("$ROOT/$trimmed")
    done

    local count
    count="$(count_matches "$pattern" "${scopes[@]}")"

    if [ "$count" -gt "$budget" ]; then
      record_failure "$label -> found $count matches (budget: $budget)"
    else
      echo "OK:   $label -> $count/$budget"
    fi
  done <<< "$rows"
}

check_done_slice_residue() {
  local rows
  rows="$(ruby -ryaml -e '
    data = YAML.load_file(ARGV[0]) || {}
    Array(data["slices"]).each do |slice|
      next unless slice["status"] == "done"
      Array(slice["residue_queries"]).each do |query|
        fields = [
          slice["id"],
          query["pattern"],
          query["scope"],
          query["reason"],
        ]
        puts fields.map { |value| value.to_s.gsub("\t", " ") }.join("\t")
      end
    end
  ' "$SLICES_FILE")"

  while IFS=$'\t' read -r slice_id pattern scope reason; do
    [ -z "$slice_id" ] && continue

    IFS=',' read -r -a raw_scopes <<< "$scope"
    local scopes=()
    local raw trimmed
    for raw in "${raw_scopes[@]}"; do
      trimmed="$(trim "$raw")"
      [ -z "$trimmed" ] && continue
      scopes+=("$ROOT/$trimmed")
    done

    local count
    count="$(count_matches "$pattern" "${scopes[@]}")"

    if [ "$count" -gt 0 ]; then
      record_failure "$slice_id residue query matched $count time(s): $reason"
    else
      echo "OK:   $slice_id residue -> clean"
    fi
  done <<< "$rows"
}

check_temp_artifacts() {
  local count
  count="$( (rg --files "$PLAN_DIR" | rg '(\.orig$|\.rej$|~$|/tmp/|/old/|/new/|/final/)' || true) | wc -l | tr -d ' ' )"
  if [ "$count" -gt 0 ]; then
    record_failure "temporary or scratch artifacts found in plan directory ($count match(es))"
  else
    echo "OK:   no temporary or scratch artifacts in plan directory"
  fi
}

echo "== Control plane =="
check_required_files
check_map_paths

echo
echo "== Ratchets =="
check_ratchets

echo
echo "== Done-slice residue =="
check_done_slice_residue

echo
echo "== Scratch sweep =="
check_temp_artifacts

echo
if [ "$ERRORS" -gt 0 ]; then
  echo "FAILED: $ERRORS guard violation(s)"
  exit 1
fi

echo "All guards pass"
exit 0

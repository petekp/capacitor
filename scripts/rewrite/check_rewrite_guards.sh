#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-check}"
if [[ "$MODE" != "check" && "$MODE" != "--status" ]]; then
  echo "Usage: $0 [check|--status]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
SLICES_FILE="$ROOT/rewrite/SLICES.yaml"
MAP_FILE="$ROOT/rewrite/MAP.csv"

failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

contains_glob() {
  local input="$1"
  [[ "$input" == *"*"* || "$input" == *"?"* || "$input" == *"["* ]]
}

if [[ ! -f "$SLICES_FILE" ]]; then
  fail "Missing rewrite slices file: $SLICES_FILE"
fi

if [[ ! -f "$MAP_FILE" ]]; then
  fail "Missing rewrite map file: $MAP_FILE"
fi

if (( failures > 0 )); then
  exit 1
fi

collect_changed_files() {
  if [[ -n "${GITHUB_BASE_REF:-}" ]]; then
    git -C "$ROOT" fetch --no-tags --prune --depth=1 origin "$GITHUB_BASE_REF" >/dev/null 2>&1 || true
    if git -C "$ROOT" rev-parse --verify "origin/$GITHUB_BASE_REF" >/dev/null 2>&1; then
      local base
      base="$(git -C "$ROOT" merge-base HEAD "origin/$GITHUB_BASE_REF")"
      git -C "$ROOT" diff --name-only --diff-filter=ACMRD "$base...HEAD"
      return
    fi
  fi

  {
    git -C "$ROOT" diff --name-only --diff-filter=ACMRD
    git -C "$ROOT" diff --cached --name-only --diff-filter=ACMRD
  } | sort -u
}

map_paths=()
while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  map_paths+=("$path")
done < <(
  ruby -rcsv -e '
    CSV.foreach(ARGV[0], headers: true) do |row|
      ["current_path", "target_path"].each do |key|
        value = row[key]
        next if value.nil?
        value = value.strip
        next if value.empty? || value == "-"
        puts value
      end
    end
  ' "$MAP_FILE"
)

exact_map_paths=()
glob_map_paths=()
for path in "${map_paths[@]}"; do
  if contains_glob "$path"; then
    glob_map_paths+=("$path")
  else
    exact_map_paths+=("$path")
  fi
done

changed_files=()
while IFS= read -r changed; do
  [[ -z "$changed" ]] && continue
  changed_files+=("$changed")
done < <(collect_changed_files)

if (( ${#changed_files[@]} > 0 )); then
  for file in "${changed_files[@]}"; do
    mapped=false

    for exact in "${exact_map_paths[@]}"; do
      if [[ "$file" == "$exact" ]]; then
        mapped=true
        break
      fi
    done

    if [[ "$mapped" == false ]]; then
      for pattern in "${glob_map_paths[@]}"; do
        if [[ "$file" == $pattern ]]; then
          mapped=true
          break
        fi
      done
    fi

    if [[ "$mapped" == false ]]; then
      fail "Touched file is not mapped in rewrite/MAP.csv: $file"
    fi
  done
fi

# Enforce denylist patterns for active slices (in_progress and done).
while IFS=$'\t' read -r slice_id pattern; do
  [[ -z "$slice_id" || -z "$pattern" ]] && continue

  if [[ "$pattern" == content:* ]]; then
    content_rule="${pattern#content:}"
    if [[ "$content_rule" != *"::"* ]]; then
      fail "Invalid content denylist pattern in $slice_id: '$pattern' (expected content:<file_glob>::<regex>)"
      continue
    fi

    file_glob="${content_rule%%::*}"
    regex="${content_rule#*::}"
    if [[ -z "$file_glob" || -z "$regex" ]]; then
      fail "Invalid content denylist pattern in $slice_id: '$pattern' (empty file glob or regex)"
      continue
    fi

    matched_files=()
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      matched_files+=("$match")
    done < <(cd "$ROOT" && compgen -G "$file_glob" || true)

    if (( ${#matched_files[@]} == 0 )); then
      continue
    fi

    content_matches="$(cd "$ROOT" && rg -n --color never -e "$regex" "${matched_files[@]}" || true)"
    if [[ -n "$content_matches" ]]; then
      fail "Denylist content violation in $slice_id: pattern '$pattern' matched code"
      echo "$content_matches" | head -n 10 | sed 's/^/  - /'
    fi
    continue
  fi

  matches=()
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    matches+=("$match")
  done < <(cd "$ROOT" && compgen -G "$pattern" || true)

  if (( ${#matches[@]} > 0 )); then
    fail "Denylist violation in $slice_id: pattern '$pattern' matched existing paths"
    for match in "${matches[@]:0:10}"; do
      echo "  - $match"
    done
  fi
done < <(
  ruby -ryaml -e '
    data = YAML.load_file(ARGV[0]) || {}
    slices = data.fetch("slices", [])
    slices.each do |slice|
      status = slice["status"].to_s
      next unless ["in_progress", "done"].include?(status)

      Array(slice["denylist_patterns"]).each do |pattern|
        pattern = pattern.to_s.strip
        next if pattern.empty?
        puts "#{slice["id"]}\t#{pattern}"
      end
    end
  ' "$SLICES_FILE"
)

# Enforce that done slices cannot keep deletion targets.
while IFS=$'\t' read -r slice_id target; do
  [[ -z "$slice_id" || -z "$target" ]] && continue

  if contains_glob "$target"; then
    matches=()
    while IFS= read -r match; do
      [[ -z "$match" ]] && continue
      matches+=("$match")
    done < <(cd "$ROOT" && compgen -G "$target" || true)

    if (( ${#matches[@]} > 0 )); then
      fail "Done slice $slice_id still has deletion target(s) present for glob: $target"
      for match in "${matches[@]:0:10}"; do
        echo "  - $match"
      done
    fi
  else
    if [[ -e "$ROOT/$target" ]]; then
      fail "Done slice $slice_id still has deletion target present: $target"
    fi
  fi
done < <(
  ruby -ryaml -e '
    data = YAML.load_file(ARGV[0]) || {}
    slices = data.fetch("slices", [])
    slices.each do |slice|
      next unless slice["status"].to_s == "done"

      Array(slice["deletion_targets"]).each do |target|
        target = target.to_s.strip
        next if target.empty?
        puts "#{slice["id"]}\t#{target}"
      end
    end
  ' "$SLICES_FILE"
)

if [[ "$MODE" == "--status" ]]; then
  ruby -ryaml -e '
    data = YAML.load_file(ARGV[0]) || {}
    slices = data.fetch("slices", [])
    counts = slices.group_by { |slice| slice["status"].to_s }

    puts "Rewrite Guard Status"
    puts "  total_slices: #{slices.length}"
    puts "  pending: #{counts.fetch("pending", []).length}"
    puts "  in_progress: #{counts.fetch("in_progress", []).length}"
    puts "  blocked: #{counts.fetch("blocked", []).length}"
    puts "  done: #{counts.fetch("done", []).length}"

    in_progress_ids = slices.select { |slice| slice["status"].to_s == "in_progress" }.map { |slice| slice["id"] }
    if in_progress_ids.empty?
      puts "  active_slices: none"
    else
      puts "  active_slices: #{in_progress_ids.join(", ")}"
    end
  ' "$SLICES_FILE"
fi

if (( failures > 0 )); then
  echo "Rewrite guard checks failed with $failures error(s)."
  exit 1
fi

echo "Rewrite guard checks passed."

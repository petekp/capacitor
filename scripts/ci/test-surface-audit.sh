#!/usr/bin/env bash
set -euo pipefail

MODE="${1:---check}"
if [[ "$MODE" != "--check" && "$MODE" != "--report" ]]; then
  echo "Usage: $0 [--check|--report]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

failures=0
warn_or_fail() {
  local message="$1"
  if [[ "$MODE" == "--check" ]]; then
    echo "FAIL: $message"
    failures=$((failures + 1))
  else
    echo "WARN: $message"
  fi
}

SWIFT_TEST_DIR="apps/swift/Tests/CapacitorTests"

# Frozen baselines (update intentionally when we pay down test debt).
SOURCE_CONTAINS_MAX_FILES=0
SOURCE_CONTAINS_MAX_METHODS=0
SOURCE_CONTAINS_MAX_ASSERTS=0
TASK_SLEEP_MAX_CALLS=0
STATIC_BATS_MAX_SOURCE_ASSERT_LINES=0

SOURCE_CONTAINS_ALLOWLIST=''

TASK_SLEEP_ALLOWLIST=''

is_in_allowlist() {
  local value="$1"
  local list="$2"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == "$value" ]]; then
      return 0
    fi
  done <<EOF
$list
EOF
  return 1
}

source_contains_files="$(rg -l "source\\.contains" "$SWIFT_TEST_DIR" || true)"
if [[ -n "$source_contains_files" ]]; then
  source_contains_file_count=$(printf '%s\n' "$source_contains_files" | sed '/^$/d' | wc -l | tr -d ' ')
else
  source_contains_file_count=0
fi
source_contains_assert_count=$(
  (rg -n "source\\.contains" "$SWIFT_TEST_DIR" || true) | wc -l | tr -d ' '
)

source_contains_method_count=0
if [[ -n "$source_contains_files" ]]; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    method_count=$(rg -n "func test" "$file" | wc -l | tr -d ' ')
    source_contains_method_count=$((source_contains_method_count + method_count))
    if ! is_in_allowlist "$file" "$SOURCE_CONTAINS_ALLOWLIST"; then
      warn_or_fail "New source.contains test file outside allowlist: $file"
    fi
  done <<EOF
$source_contains_files
EOF
fi

if (( source_contains_file_count > SOURCE_CONTAINS_MAX_FILES )); then
  warn_or_fail "source.contains files grew ($source_contains_file_count > $SOURCE_CONTAINS_MAX_FILES)"
fi
if (( source_contains_method_count > SOURCE_CONTAINS_MAX_METHODS )); then
  warn_or_fail "test methods in source.contains files grew ($source_contains_method_count > $SOURCE_CONTAINS_MAX_METHODS)"
fi
if (( source_contains_assert_count > SOURCE_CONTAINS_MAX_ASSERTS )); then
  warn_or_fail "source.contains assertions grew ($source_contains_assert_count > $SOURCE_CONTAINS_MAX_ASSERTS)"
fi

task_sleep_files="$(rg -l "Task\\.sleep|_Concurrency\\.Task\\.sleep|Thread\\.sleep|usleep" "$SWIFT_TEST_DIR" || true)"
if [[ -n "$task_sleep_files" ]]; then
  task_sleep_file_count=$(printf '%s\n' "$task_sleep_files" | sed '/^$/d' | wc -l | tr -d ' ')
else
  task_sleep_file_count=0
fi
task_sleep_call_count=$(
  (rg -n "Task\\.sleep|_Concurrency\\.Task\\.sleep|Thread\\.sleep|usleep" "$SWIFT_TEST_DIR" || true) | wc -l | tr -d ' '
)

if [[ -n "$task_sleep_files" ]]; then
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    if ! is_in_allowlist "$file" "$TASK_SLEEP_ALLOWLIST"; then
      warn_or_fail "Task.sleep usage outside allowlist: $file"
    fi
  done <<EOF
$task_sleep_files
EOF
fi

if (( task_sleep_call_count > TASK_SLEEP_MAX_CALLS )); then
  warn_or_fail "Task.sleep call count grew ($task_sleep_call_count > $TASK_SLEEP_MAX_CALLS)"
fi

static_bats_source_assert_lines=$(
  (rg -n 'run grep.*\$PROJECT_ROOT/scripts' tests || true) | wc -l | tr -d ' '
)
if (( static_bats_source_assert_lines > STATIC_BATS_MAX_SOURCE_ASSERT_LINES )); then
  warn_or_fail "static bats source-assert lines grew ($static_bats_source_assert_lines > $STATIC_BATS_MAX_SOURCE_ASSERT_LINES)"
fi

echo "Test Surface Audit"
echo "  mode: $MODE"
echo "  source_contains_files: $source_contains_file_count"
echo "  source_contains_methods: $source_contains_method_count"
echo "  source_contains_asserts: $source_contains_assert_count"
echo "  task_sleep_files: $task_sleep_file_count"
echo "  task_sleep_calls: $task_sleep_call_count"
echo "  static_bats_source_assert_lines: $static_bats_source_assert_lines"

if (( failures > 0 )); then
  echo "Test surface audit failed with $failures violation(s)."
  exit 1
fi

echo "Test surface audit passed."

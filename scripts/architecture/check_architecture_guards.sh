#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-check}"
if [[ "$MODE" != "check" && "$MODE" != "--status" ]]; then
  echo "Usage: $0 [check|--status]"
  exit 2
fi

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
failures=0
budget_status_lines=()

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

count_pattern_matches() {
  local regex="$1"
  shift

  if command -v rg >/dev/null 2>&1; then
    { rg -o --no-filename -e "$regex" "$@" 2>/dev/null || true; } | wc -l | tr -d ' '
  else
    local grep_paths=()
    local skip_next=0

    for arg in "$@"; do
      if (( skip_next )); then
        skip_next=0
        continue
      fi

      case "$arg" in
        -g|--glob)
          skip_next=1
          ;;
        -*)
          ;;
        *)
          grep_paths+=("$arg")
          ;;
      esac
    done

    { grep -Eo -- "$regex" "${grep_paths[@]}" 2>/dev/null || true; } | wc -l | tr -d ' '
  fi
}

count_glob_matches() {
  local pattern="$1"
  local count=0
  while IFS= read -r match; do
    [[ -z "$match" ]] && continue
    count=$((count + 1))
  done < <(cd "$ROOT" && compgen -G "$pattern" || true)
  echo "$count"
}

check_budget() {
  local label="$1"
  local budget="$2"
  local regex="$3"
  shift 3

  local count
  count="$(count_pattern_matches "$regex" "$@")"
  budget_status_lines+=("$label: $count/$budget")
  if (( count > budget )); then
    fail "Budget exceeded for $label: $count > $budget"
  fi
}

check_glob_budget() {
  local label="$1"
  local budget="$2"
  local pattern="$3"

  local count
  count="$(count_glob_matches "$pattern")"
  budget_status_lines+=("$label: $count/$budget")
  if (( count > budget )); then
    fail "Budget exceeded for $label: $count > $budget"
  fi
}

check_path_absent() {
  local label="$1"
  local pattern="$2"
  local count
  count="$(count_glob_matches "$pattern")"
  budget_status_lines+=("$label: $count/0")
  if (( count > 0 )); then
    fail "Retired path still present for $label: $pattern"
  fi
}

check_content_absent() {
  local label="$1"
  local file="$2"
  local regex="$3"
  local count
  count="$(count_pattern_matches "$regex" "$file")"
  budget_status_lines+=("$label: $count/0")
  if (( count > 0 )); then
    fail "Retired content still present for $label in $file"
  fi
}

check_budget \
  "rust_context_services_scaffold_todos" \
  0 \
  'todo!\("Shell scaffold only"\)' \
  core/capacitor-core/src/contexts/*/application.rs

check_budget \
  "core_runtime_runtime_ideas_calls" \
  0 \
  'runtime_ideas::' \
  core/capacitor-core/src/lib.rs

check_budget \
  "core_runtime_project_config_helper_calls" \
  0 \
  'load_hud_config_with_storage|save_hud_config_with_storage|load_projects_with_storage|runtime_projects::try_resolve_encoded_path|validate_project_path\(|create_claude_md\(' \
  core/capacitor-core/src/lib.rs

check_budget \
  "core_runtime_setup_checker_calls" \
  0 \
  'setup_checker\(' \
  core/capacitor-core/src/lib.rs

check_budget \
  "swift_project_catalog_bridge_calls" \
  0 \
  'ProjectCatalogBridge' \
  apps/swift/Sources/Capacitor

check_glob_budget \
  "swift_models_top_level_files" \
  0 \
  'apps/swift/Sources/Capacitor/Models/*.swift'

check_glob_budget \
  "swift_models_window_anchoring_files" \
  0 \
  'apps/swift/Sources/Capacitor/Models/WindowAnchoring/*.swift'

check_glob_budget \
  "swift_features_top_level_files" \
  0 \
  'apps/swift/Sources/Capacitor/Features/*.swift'

check_budget \
  "swift_setup_requirements_manager_refs" \
  0 \
  'SetupRequirementsManager' \
  apps/swift/Sources/Capacitor/Application \
  apps/swift/Sources/Capacitor/Composition

check_budget \
  "swift_active_project_resolver_refs" \
  0 \
  'ActiveProjectResolver' \
  apps/swift/Sources/Capacitor/Application

check_budget \
  "swift_project_ingestion_worker_refs" \
  0 \
  'ProjectIngestionWorker' \
  apps/swift/Sources/Capacitor/Application

check_budget \
  "swift_session_state_manager_refs" \
  0 \
  'SessionStateManager' \
  -g '!SessionStateManager.swift' \
  apps/swift/Sources/Capacitor/Application

check_budget \
  "swift_shell_state_store_refs" \
  0 \
  'ShellStateStore' \
  -g '!ShellStateStore.swift' \
  apps/swift/Sources/Capacitor/Application

check_budget \
  "swift_runtime_client_refs" \
  0 \
  'RuntimeClient' \
  apps/swift/Sources/Capacitor/Adapters \
  apps/swift/Sources/Capacitor/Debug \
  apps/swift/Sources/Capacitor/Utilities

check_budget \
  "swift_terminal_launcher_refs" \
  0 \
  'TerminalLauncher' \
  apps/swift/Sources/Capacitor/Adapters \
  apps/swift/Sources/Capacitor/Composition

check_budget \
  "swift_project_feature_type_refs" \
  0 \
  'ProjectFeatureCoordinator' \
  apps/swift/Sources/Capacitor

check_budget \
  "historical_checkpoint_user_run_todos" \
  0 \
  'TODO \(user-run\)' \
  docs/archive/audit/ARCHITECTURE_CHECKPOINT_2026-03-06.md \
  docs/archive/audit/ARCHITECTURE_CHECKPOINT_2026-03-07.md

check_path_absent "retired_review_package" 'tmp/review-package/*'
check_path_absent "retired_swift_features" 'apps/swift/Sources/Capacitor/Features/*'

check_content_absent \
  "retired_appstate_runtime_refresh" \
  "$ROOT/apps/swift/Sources/Capacitor/Composition/AppState.swift" \
  'sessionStateManager\.refreshSessionStates\(|shellStateStore\.stopPolling\(|fetch(ProjectStates|Sessions|ShellState)\('

check_content_absent \
  "retired_session_state_fetch" \
  "$ROOT/apps/swift/Sources/Capacitor/Application/Runtime/SessionStateManager.swift" \
  'fetchProjectStates\('

check_content_absent \
  "retired_shell_state_fetch" \
  "$ROOT/apps/swift/Sources/Capacitor/Application/Runtime/ShellStateStore.swift" \
  'fetchShellState\('

if [[ "$MODE" == "--status" ]]; then
  echo "Architecture Guard Status"
  for entry in "${budget_status_lines[@]}"; do
    echo "  $entry"
  done
fi

if (( failures > 0 )); then
  echo "Architecture guard checks failed with $failures error(s)."
  exit 1
fi

echo "Architecture guard checks passed."

#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"

smoke_script="${AX_AUTOMATION_SMOKE_SCRIPT:-${workspace_root}/scripts/ci/non-demo-ax-smoke.sh}"
default_artifacts_dir="${workspace_root}/artifacts/ax-automation-verification"
default_debug_log="${CAPACITOR_APP_DEBUG_LOG:-$HOME/.capacitor/runtime/app-debug.log}"
default_projects_file="${CAPACITOR_PROJECTS_FILE:-$HOME/.capacitor/projects.json}"

runs=1
skip_details=0
require_log_health=0
allow_untrusted=0
artifacts_dir="$default_artifacts_dir"
runs_log_prefix=""
debug_log="$default_debug_log"
projects_file="$default_projects_file"

usage() {
    cat <<'USAGE'
Usage: bash scripts/ci/ax-automation-verify.sh [options]

Runs one or more AX smoke verification passes, captures per-run evidence, and
fails on deterministic AX regressions.

Options:
  --runs <n>               Number of verification runs (default: 1)
  --skip-details           Only run the stable/cards smoke phase
  --require-log-health     Enforce fresh [WindowAX] lifecycle evidence
  --allow-untrusted        Treat missing AX trust as a non-blocking skip
  --artifacts-dir <path>   Root artifact directory
  --runs-log-prefix <path> Prefix used for per-run artifact folders
  --debug-log <path>       Override app debug log path
  --help                   Show this help text
USAGE
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "Missing required command: $cmd" >&2
        exit 1
    fi
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --runs)
            [[ $# -ge 2 ]] || { echo "--runs requires a value" >&2; exit 1; }
            [[ "$2" =~ ^[0-9]+$ ]] && [[ "$2" -ge 1 ]] || { echo "--runs must be >= 1" >&2; exit 1; }
            runs="$2"
            shift 2
            ;;
        --skip-details)
            skip_details=1
            shift
            ;;
        --require-log-health)
            require_log_health=1
            shift
            ;;
        --allow-untrusted)
            allow_untrusted=1
            shift
            ;;
        --artifacts-dir)
            [[ $# -ge 2 ]] || { echo "--artifacts-dir requires a value" >&2; exit 1; }
            artifacts_dir="$2"
            shift 2
            ;;
        --runs-log-prefix)
            [[ $# -ge 2 ]] || { echo "--runs-log-prefix requires a value" >&2; exit 1; }
            runs_log_prefix="$2"
            shift 2
            ;;
        --debug-log)
            [[ $# -ge 2 ]] || { echo "--debug-log requires a value" >&2; exit 1; }
            debug_log="$2"
            shift 2
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
        esac
    done
}

count_distinct_pinned_projects() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        printf '0\n'
        return
    fi

    jq -r '.pinned_projects[]? // empty' "$path" | awk 'NF && !seen[$0]++ { count += 1 } END { print count + 0 }'
}

build_seeded_projects_file() {
    local output_path="$1"
    local -a candidates=(
        "$workspace_root"
        "$workspace_root/apps/swift"
        "$workspace_root/core"
    )
    local -a selected=()
    local candidate=""

    for candidate in "${candidates[@]}"; do
        [[ -d "$candidate" ]] || continue
        if [[ " ${selected[*]} " != *" ${candidate} "* ]]; then
            selected+=("$candidate")
        fi
        if [[ "${#selected[@]}" -ge 2 ]]; then
            break
        fi
    done

    if [[ "${#selected[@]}" -lt 2 ]]; then
        echo "Could not build a seeded projects file with two repo-owned paths." >&2
        return 1
    fi

    mkdir -p "$(dirname "$output_path")"
    jq -n \
        --arg path_one "${selected[0]}" \
        --arg path_two "${selected[1]}" \
        '{pinned_projects: [$path_one, $path_two]}' >"$output_path"
}

prepare_projects_file() {
    local run_dir="$1"
    local pinned_count
    pinned_count="$(count_distinct_pinned_projects "$projects_file")"
    if [[ "$pinned_count" -ge 2 ]]; then
        printf '%s\n' "$projects_file"
        return
    fi

    local seeded_projects_file="${run_dir}/projects.seed.json"
    build_seeded_projects_file "$seeded_projects_file"
    printf '%s\n' "$seeded_projects_file"
}

log_file_size() {
    local path="$1"
    if [[ -f "$path" ]]; then
        wc -c <"$path" | tr -d '[:space:]'
    else
        printf '0\n'
    fi
}

slice_debug_log() {
    local source_path="$1"
    local start_size="$2"
    local output_path="$3"

    mkdir -p "$(dirname "$output_path")"
    if [[ ! -f "$source_path" ]]; then
        : >"$output_path"
        return
    fi

    local start_byte=$((start_size + 1))
    tail -c +"$start_byte" "$source_path" >"$output_path"
}

contains_accessibility_not_trusted() {
    local path="$1"
    [[ -f "$path" ]] && grep -q 'Accessibility permission is required for AX automation\.' "$path"
}

contains_no_ax_windows() {
    local path="$1"
    [[ -f "$path" ]] && grep -q 'No AX windows were found for' "$path"
}

contains_timeout_error() {
    local path="$1"
    [[ -f "$path" ]] && grep -Eq 'Timed out waiting [0-9.]+s for (app|AX identifier)|step timeout|runner timeout' "$path"
}

contains_runner_error() {
    local path="$1"
    [[ -f "$path" ]] && grep -Eq '"event":"runner\.error"|ax_runner error:' "$path"
}

has_runner_complete() {
    local path="$1"
    [[ -f "$path" ]] && grep -q '"event":"runner.complete"' "$path"
}

classify_phase_failure() {
    local path="$1"

    if contains_accessibility_not_trusted "$path"; then
        printf 'accessibility_not_trusted\n'
        return
    fi
    if contains_no_ax_windows "$path"; then
        printf 'no_ax_windows\n'
        return
    fi
    if contains_timeout_error "$path"; then
        printf 'timeout\n'
        return
    fi
    if [[ ! -f "$path" ]]; then
        printf 'missing_log\n'
        return
    fi
    if ! has_runner_complete "$path"; then
        printf 'missing_runner_complete\n'
        return
    fi
    if contains_runner_error "$path"; then
        printf 'runner_error\n'
        return
    fi
    printf '\n'
}

classify_window_lifecycle_health() {
    local path="$1"

    if [[ ! -s "$path" ]]; then
        printf 'missing_window_log_slice\n'
        return
    fi
    if ! grep -q '\[WindowAX\] applicationDidBecomeActive appWindowCount=' "$path"; then
        printf 'missing_applicationDidBecomeActive\n'
        return
    fi
    if ! grep -q '\[WindowAX\] context=applicationDidBecomeActive ' "$path"; then
        printf 'missing_applicationDidBecomeActive_context\n'
        return
    fi
    if ! grep -q '\[WindowAX\] context=didBecomeKey ' "$path"; then
        printf 'missing_didBecomeKey\n'
        return
    fi
    if ! grep -Eq '\[WindowAX\].*isKey=true.*isMain=true' "$path"; then
        printf 'missing_isKey_isMain_true\n'
        return
    fi
    printf 'pass\n'
}

collect_phase_log() {
    local smoke_artifacts_dir="$1"
    local phase="$2"

    find "$smoke_artifacts_dir" -maxdepth 1 -type f -name "non-demo-ax-smoke-${phase}-*.log" | LC_ALL=C sort | tail -n 1
}

run_smoke() {
    local run_dir="$1"
    local smoke_artifacts_dir="$2"
    local projects_path="$3"
    local run_log="$4"

    local -a cmd=(bash "$smoke_script" --artifacts-dir "$smoke_artifacts_dir" --projects-file "$projects_path")
    if [[ "$skip_details" -eq 1 ]]; then
        cmd+=(--skip-details)
    fi

    set +e
    "${cmd[@]}" > >(tee "$run_log") 2>&1
    local status=$?
    set -e
    return "$status"
}

main() {
    parse_args "$@"

    require_cmd jq
    require_cmd tee

    local session_timestamp
    session_timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
    if [[ -z "$runs_log_prefix" ]]; then
        runs_log_prefix="${artifacts_dir%/}/${session_timestamp}/run"
    fi

    local artifact_session_dir
    artifact_session_dir="$(dirname "$runs_log_prefix")"
    mkdir -p "$artifact_session_dir"

    local summary_file="${artifact_session_dir}/summary.txt"
    local summary_json="${artifact_session_dir}/summary.json"
    local runs_report="${artifact_session_dir}/runs.tsv"
    : >"$runs_report"

    local runs_passed=0
    local runs_skipped_untrusted=0
    local first_failure_context="none"
    local global_window_lifecycle_health="skipped"
    if [[ "$require_log_health" -eq 1 ]]; then
        global_window_lifecycle_health="pass"
    fi

    local run_index=0
    while [[ "$run_index" -lt "$runs" ]]; do
        run_index=$((run_index + 1))
        local run_label
        run_label="$(printf '%03d' "$run_index")"
        local run_dir="${runs_log_prefix}-${run_label}"
        local smoke_artifacts_dir="${run_dir}/smoke"
        local run_log="${run_dir}/smoke-run.log"
        local run_debug_log="${run_dir}/app-debug.slice.log"
        mkdir -p "$smoke_artifacts_dir"

        local projects_path
        projects_path="$(prepare_projects_file "$run_dir")"

        local debug_log_start_size
        debug_log_start_size="$(log_file_size "$debug_log")"

        local smoke_status=0
        if run_smoke "$run_dir" "$smoke_artifacts_dir" "$projects_path" "$run_log"; then
            smoke_status=0
        else
            smoke_status=$?
        fi

        slice_debug_log "$debug_log" "$debug_log_start_size" "$run_debug_log"

        local -a expected_phases=("cards")
        if [[ "$skip_details" -eq 0 ]]; then
            expected_phases+=("details")
        fi

        local outcome="pass"
        local failure_context="none"
        local window_health="skipped"
        local cards_log=""
        local details_log=""
        cards_log="$(collect_phase_log "$smoke_artifacts_dir" "cards")"
        details_log="$(collect_phase_log "$smoke_artifacts_dir" "details")"

        local phase=""
        for phase in "${expected_phases[@]}"; do
            local phase_log=""
            case "$phase" in
            cards)
                phase_log="$cards_log"
                ;;
            details)
                phase_log="$details_log"
                ;;
            esac

            local reason=""
            reason="$(classify_phase_failure "$phase_log")"
            if [[ -z "$reason" && "$smoke_status" -ne 0 ]]; then
                reason="$(classify_phase_failure "$run_log")"
                if [[ -z "$reason" ]]; then
                    reason="smoke_exit_status_${smoke_status}"
                fi
            fi

            if [[ -n "$reason" ]]; then
                if [[ "$allow_untrusted" -eq 1 && "$reason" == "accessibility_not_trusted" ]]; then
                    outcome="skipped_untrusted"
                    failure_context="run=${run_index} phase=${phase} reason=${reason}(non_blocking)"
                    break
                fi
                outcome="fail"
                failure_context="run=${run_index} phase=${phase} reason=${reason}"
                break
            fi
        done

        if [[ "$outcome" == "pass" && "$require_log_health" -eq 1 ]]; then
            window_health="$(classify_window_lifecycle_health "$run_debug_log")"
            if [[ "$window_health" != "pass" ]]; then
                outcome="fail"
                failure_context="run=${run_index} phase=window_lifecycle reason=${window_health}"
            fi
        elif [[ "$outcome" == "skipped_untrusted" ]]; then
            window_health="skipped_untrusted"
        fi

        case "$outcome" in
        pass)
            runs_passed=$((runs_passed + 1))
            ;;
        skipped_untrusted)
            runs_skipped_untrusted=$((runs_skipped_untrusted + 1))
            if [[ "$global_window_lifecycle_health" == "pass" || "$global_window_lifecycle_health" == "skipped" ]]; then
                global_window_lifecycle_health="skipped_untrusted"
            fi
            ;;
        fail)
            if [[ "$failure_context" == *"phase=window_lifecycle"* ]]; then
                global_window_lifecycle_health="fail"
            elif [[ "$require_log_health" -eq 1 && "$global_window_lifecycle_health" != "fail" ]]; then
                global_window_lifecycle_health="skipped"
            fi
            ;;
        esac

        if [[ "$first_failure_context" == "none" && "$failure_context" != "none" ]]; then
            first_failure_context="$failure_context"
        fi

        printf 'run\t%s\t%s\t%s\t%s\n' \
            "$run_index" \
            "$outcome" \
            "$window_health" \
            "$run_dir" >>"$runs_report"

        echo "run=${run_index} outcome=${outcome} window_lifecycle_health=${window_health} artifacts=${run_dir}"
    done

    if [[ "$require_log_health" -eq 0 && "$runs_skipped_untrusted" -eq 0 && "$global_window_lifecycle_health" != "fail" ]]; then
        global_window_lifecycle_health="skipped"
    fi

    {
        echo "runs_requested=${runs}"
        echo "runs_passed=${runs_passed}"
        echo "runs_skipped_untrusted=${runs_skipped_untrusted}"
        echo "window_lifecycle_health=${global_window_lifecycle_health}"
        echo "first_failure_context=${first_failure_context}"
        echo "artifacts_dir=${artifact_session_dir}"
        echo "runs_report=${runs_report}"
        echo "summary_json=${summary_json}"
    } | tee "$summary_file"

    jq -n \
        --argjson runs_requested "$runs" \
        --argjson runs_passed "$runs_passed" \
        --argjson runs_skipped_untrusted "$runs_skipped_untrusted" \
        --arg window_lifecycle_health "$global_window_lifecycle_health" \
        --arg first_failure_context "$first_failure_context" \
        --arg artifacts_dir "$artifact_session_dir" \
        --arg runs_report "$runs_report" \
        '{
            runs_requested: $runs_requested,
            runs_passed: $runs_passed,
            runs_skipped_untrusted: $runs_skipped_untrusted,
            window_lifecycle_health: $window_lifecycle_health,
            first_failure_context: $first_failure_context,
            artifacts_dir: $artifacts_dir,
            runs_report: $runs_report
        }' >"$summary_json"

    if [[ "$runs_passed" -eq "$runs" ]]; then
        exit 0
    fi

    if [[ "$allow_untrusted" -eq 1 && $((runs_passed + runs_skipped_untrusted)) -eq "$runs" ]]; then
        exit 0
    fi

    exit 1
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi

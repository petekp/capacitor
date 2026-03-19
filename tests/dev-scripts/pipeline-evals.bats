#!/usr/bin/env bats

source "$BATS_TEST_DIRNAME/helpers.bash"

setup() {
    setup_test_workspace with_home

    mkdir -p \
        "$TEST_HOME/.claude/skills/manage-codex/references" \
        "$TEST_HOME/.claude/skills/demo"
}

teardown() {
    teardown_test_workspace
}

new_test_repo() {
    local name="$1"
    local repo="$TEST_DIR/$name"

    mkdir -p \
        "$repo/scripts/pipeline" \
        "$repo/scripts/relay"

    copy_project_scripts "$repo" \
        scripts/pipeline/update-pipeline.sh \
        scripts/relay/update-batch.sh \
        scripts/relay/compose-prompt.sh

    init_git_repo "$repo"

    printf '%s\n' "$repo"
}

clone_test_repo() {
    local source_repo="$1"
    local dest_repo

    dest_repo="$(mktemp -d "$TEST_DIR/repo-copy.XXXXXX")"
    cp -R "$source_repo/." "$dest_repo/"
    printf '%s\n' "$dest_repo"
}

repo_path() {
    local repo="$1"
    local rel_path="$2"

    printf '%s/%s\n' "$repo" "${rel_path#./}"
}

pipeline_file_path() {
    local repo="$1"
    local name="$2"

    repo_path "$repo" ".pipeline/$name"
}

relay_file_path() {
    local repo="$1"
    local root_rel="$2"
    local name="$3"

    printf '%s/%s\n' "$(repo_path "$repo" "$root_rel")" "$name"
}

write_valid_constraints_json() {
    local path="$1"

    write_fixture "$path" <<'EOF'
{
  "schema_version": 1,
  "allowed_paths": [
    "scripts/pipeline/update-pipeline.sh",
    "tests/dev-scripts/pipeline-evals.bats"
  ],
  "interface_changes": [
    "Add targeted pipeline eval coverage"
  ],
  "verification_commands": [
    "bats tests/dev-scripts/pipeline-evals.bats"
  ],
  "non_goals": [
    "No Swift or Rust changes"
  ],
  "open_questions": []
}
EOF
}

write_batch_fixture_in() {
    local repo="$1"
    local root_rel="${2:-.relay}"

    mkdir -p "$(repo_path "$repo" "$root_rel")"
    cat > "$(relay_file_path "$repo" "$root_rel" "batch.json")"
}

write_plan_fixture_in() {
    local repo="$1"
    local root_rel="${2:-.relay}"

    mkdir -p "$(repo_path "$repo" "$root_rel")"
    cat > "$(relay_file_path "$repo" "$root_rel" "plan.json")"
}

copy_batch_to_plan_in() {
    local repo="$1"
    local root_rel="${2:-.relay}"

    cp \
        "$(relay_file_path "$repo" "$root_rel" "batch.json")" \
        "$(relay_file_path "$repo" "$root_rel" "plan.json")"
}

file_signature() {
    local path="$1"

    if [ ! -e "$path" ]; then
        printf 'missing:%s\n' "$path"
        return
    fi

    printf 'sha256:%s:%s\n' \
        "$path" \
        "$(shasum -a 256 "$path" | awk '{print $1}')"
}

capture_signatures() {
    local path

    for path in "$@"; do
        file_signature "$path"
    done
}

run_update_pipeline_in() {
    local repo="$1"
    shift

    run env HOME="$TEST_HOME" REPO_DIR="$repo" /bin/bash -lc \
        'cd "$REPO_DIR" && ./scripts/pipeline/update-pipeline.sh "$@"' \
        bash "$@"
}

run_update_batch_in() {
    local repo="$1"
    shift

    run env HOME="$TEST_HOME" REPO_DIR="$repo" /bin/bash -lc \
        'cd "$REPO_DIR" && ./scripts/relay/update-batch.sh "$@"' \
        bash "$@"
}

run_compose_prompt_in() {
    local repo="$1"
    shift

    run env HOME="$TEST_HOME" REPO_DIR="$repo" /bin/bash -lc \
        'cd "$REPO_DIR" && ./scripts/relay/compose-prompt.sh "$@"' \
        bash "$@"
}

run_crashy_update_pipeline_in() {
    local repo="$1"
    shift

    run env HOME="$TEST_HOME" REPO_DIR="$repo" PIPELINE_EVAL_CRASH_AFTER_APPEND=1 /bin/bash -lc \
        'cd "$REPO_DIR" && ./scripts/pipeline/update-pipeline.sh "$@"' \
        bash "$@"
}

run_crashy_update_batch_in() {
    local repo="$1"
    shift

    run env HOME="$TEST_HOME" REPO_DIR="$repo" BATCH_EVAL_CRASH_AFTER_APPEND=1 /bin/bash -lc \
        'cd "$REPO_DIR" && ./scripts/relay/update-batch.sh "$@"' \
        bash "$@"
}

assert_pipeline_rejected_without_mutation() {
    local repo="$1"
    local expected="$2"
    shift 2

    local before
    before="$(capture_signatures \
        "$(pipeline_file_path "$repo" "state.json")" \
        "$(pipeline_file_path "$repo" "events.ndjson")")"

    run_update_pipeline_in "$repo" "$@"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]]

    [ "$before" = "$(capture_signatures \
        "$(pipeline_file_path "$repo" "state.json")" \
        "$(pipeline_file_path "$repo" "events.ndjson")")" ]
}

assert_batch_rejected_without_mutation() {
    local repo="$1"
    local expected="$2"
    shift 2

    local before
    before="$(capture_signatures \
        "$(relay_file_path "$repo" ".relay" "batch.json")" \
        "$(relay_file_path "$repo" ".relay" "events.ndjson")")"

    run_update_batch_in "$repo" "$@"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]]

    [ "$before" = "$(capture_signatures \
        "$(relay_file_path "$repo" ".relay" "batch.json")" \
        "$(relay_file_path "$repo" ".relay" "events.ndjson")")" ]
}

assert_compose_rejected_without_output() {
    local repo="$1"
    local expected="$2"
    local out_path="$3"
    shift 3

    local before
    before="$(capture_signatures "$out_path")"

    run_compose_prompt_in "$repo" "$@"
    [ "$status" -ne 0 ]
    [[ "$output" == *"$expected"* ]]

    [ "$before" = "$(capture_signatures "$out_path")" ]
}

create_initialized_pipeline_repo() {
    local name="$1"
    local mission_id="${2:-mission-001}"
    local repo

    repo="$(new_test_repo "$name")"

    run_update_pipeline_in "$repo" --event init_pipeline --mission-id "$mission_id"
    [ "$status" -eq 0 ]

    printf '%s\n' "$repo"
}

prepare_align_gate_inputs_for_phase() {
    local repo="$1"
    local phase_id="$2"
    local spec_rel="e-$phase_id.md"
    local plan_rel="v-$phase_id.md"
    local constraints_rel=".pipeline/phases/$phase_id/artifacts/constraints.json"

    write_fixture "$(repo_path "$repo" "$spec_rel")" <<EOF
# Execution Spec

Prepare $phase_id for deterministic execution.
EOF

    write_fixture "$(repo_path "$repo" "$plan_rel")" <<'EOF'
# Verification Plan

- bats tests/dev-scripts/pipeline-evals.bats
EOF

    write_valid_constraints_json "$(repo_path "$repo" "$constraints_rel")"

    run_update_pipeline_in "$repo" \
        --event artifact_recorded \
        --phase-id "$phase_id" \
        --artifact-id execution-spec \
        --artifact-path "$spec_rel" \
        --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" \
        --event artifact_recorded \
        --phase-id "$phase_id" \
        --artifact-id verification-plan \
        --artifact-path "$plan_rel" \
        --artifact-role output
    [ "$status" -eq 0 ]
}

write_pipeline_adapter_status() {
    local path="$1"
    local phase_id="$2"
    local status="$3"
    local checkpoint_at="$4"
    local total_slices="${5:-3}"
    local completed_slices="${6:-1}"

    python3 - "$path" "$phase_id" "$status" "$checkpoint_at" "$total_slices" "$completed_slices" <<'PY'
import json
import sys

path, phase_id, status, checkpoint_at, total_slices, completed_slices = sys.argv[1:7]
total_slices = int(total_slices)
completed_slices = int(completed_slices)

payload = {
    "schema_version": 2,
    "adapter_id": "manage-codex-relay",
    "phase_id": phase_id,
    "pipeline_root": ".pipeline",
    "relay_root": f".pipeline/phases/{phase_id}/runtime/relay",
    "status": status,
    "progress_summary": f"{status} {phase_id}",
    "current_child_phase": "review",
    "current_slice_id": "slice-001",
    "current_operation": f"op {status}",
    "counts": {
        "total_slices": total_slices,
        "completed_slices": completed_slices,
        "review_rejections": 0,
        "convergence_attempts": 0,
        "elapsed_seconds": 12,
        "retry_count": 0,
    },
    "latest_artifacts": {
        "handoff_path": f".pipeline/phases/{phase_id}/runtime/relay/handoffs/handoff-slice-001.md",
        "handoff_sha256": "sha256:handoff",
        "review_findings_path": f".pipeline/phases/{phase_id}/runtime/relay/review-findings/review-findings-slice-001.md",
        "review_findings_sha256": "sha256:review",
    },
    "last_checkpoint_at": checkpoint_at,
    "verdict": {"status": "clean", "summary": "done"} if status == "complete" else None,
}

with open(path, "w") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

stage_manage_codex_fixture() {
    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/implement-template.md" <<'EOF'
# Implement Template
Relay root: {relay_root}
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/relay-protocol.md" <<'EOF'
# Relay Protocol
Protocol root: {relay_root}
EOF

    write_fixture "$TEST_HOME/.claude/skills/demo/SKILL.md" <<'EOF'
# Demo Skill
Skill root: {relay_root}
EOF
}

truncate_last_line() {
    local path="$1"

    python3 - "$path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines(True)
if not lines:
    raise SystemExit("file has no lines to truncate")
lines[-1] = lines[-1][: max(1, len(lines[-1]) // 2)]
path.write_text("".join(lines))
PY
}

drop_last_line() {
    local path="$1"

    python3 - "$path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines(True)
if lines:
    path.write_text("".join(lines[:-1]))
PY
}

inject_crash_after_pipeline_append() {
    local path="$1"

    python3 - "$path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
needle = "    append_event(events_file, current_record)\n"
replacement = needle + (
    '    if os.environ.get("PIPELINE_EVAL_CRASH_AFTER_APPEND") == "1":\n'
    '        print("CRASH: injected after append_event", file=sys.stderr)\n'
    '        sys.exit(99)\n'
)

if needle not in source:
    raise SystemExit("append_event hook not found")

path.write_text(source.replace(needle, replacement, 1))
PY
}

inject_crash_after_batch_append() {
    local path="$1"

    python3 - "$path" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source = path.read_text()
needle = "append_event(events_file, record)\n"
replacement = needle + (
    'if os.environ.get("BATCH_EVAL_CRASH_AFTER_APPEND") == "1":\n'
    '    print("CRASH: injected after append_event", file=sys.stderr)\n'
    '    sys.exit(99)\n'
)

if needle not in source:
    raise SystemExit("append_event hook not found")

path.write_text(source.replace(needle, replacement, 1))
PY
}

@test "eval 4: pipeline required fields reject missing empty and whitespace without mutation" {
    local repo
    local artifact_repo
    local summary_repo

    repo="$(new_test_repo eval4-pipeline-init)"

    assert_pipeline_rejected_without_mutation "$repo" "--mission-id is required for init_pipeline" \
        --event init_pipeline
    assert_pipeline_rejected_without_mutation "$repo" "--mission-id is required for init_pipeline" \
        --event init_pipeline --mission-id ""
    assert_pipeline_rejected_without_mutation "$repo" "--mission-id must be a non-empty, non-whitespace string" \
        --event init_pipeline --mission-id "   "

    repo="$(create_initialized_pipeline_repo eval4-pipeline-phase)"

    assert_pipeline_rejected_without_mutation "$repo" "--phase-id is required for phase_added" \
        --event phase_added --phase-type align --skill-version v1
    assert_pipeline_rejected_without_mutation "$repo" "--phase-id is required for phase_added" \
        --event phase_added --phase-id "" --phase-type align --skill-version v1
    assert_pipeline_rejected_without_mutation "$repo" "--phase-id must be a non-empty, non-whitespace string" \
        --event phase_added --phase-id "   " --phase-type align --skill-version v1

    assert_pipeline_rejected_without_mutation "$repo" "--phase-type is required for phase_added" \
        --event phase_added --phase-id phase-001-align --skill-version v1
    assert_pipeline_rejected_without_mutation "$repo" "--phase-type is required for phase_added" \
        --event phase_added --phase-id phase-001-align --phase-type "" --skill-version v1
    assert_pipeline_rejected_without_mutation "$repo" "invalid --phase-type" \
        --event phase_added --phase-id phase-001-align --phase-type "   " --skill-version v1

    assert_pipeline_rejected_without_mutation "$repo" "--skill-version is required for phase_added" \
        --event phase_added --phase-id phase-001-align --phase-type align
    assert_pipeline_rejected_without_mutation "$repo" "--skill-version is required for phase_added" \
        --event phase_added --phase-id phase-001-align --phase-type align --skill-version ""
    assert_pipeline_rejected_without_mutation "$repo" "--skill-version must be a non-empty, non-whitespace string" \
        --event phase_added --phase-id phase-001-align --phase-type align --skill-version "   "

    artifact_repo="$(create_initialized_pipeline_repo eval4-pipeline-artifact)"
    run_update_pipeline_in "$artifact_repo" --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$artifact_repo" --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]
    write_fixture "$(repo_path "$artifact_repo" ".pipeline/phases/phase-001-align/artifacts/decision-log.md")" <<'EOF'
# Decision Log

Artifact placeholder.
EOF

    assert_pipeline_rejected_without_mutation "$artifact_repo" "--artifact-id is required for artifact_recorded" \
        --event artifact_recorded --phase-id phase-001-align --artifact-path ".pipeline/phases/phase-001-align/artifacts/decision-log.md" --artifact-role output
    assert_pipeline_rejected_without_mutation "$artifact_repo" "--artifact-id is required for artifact_recorded" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id "" --artifact-path ".pipeline/phases/phase-001-align/artifacts/decision-log.md" --artifact-role output
    assert_pipeline_rejected_without_mutation "$artifact_repo" "--artifact-id must be a non-empty, non-whitespace string" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id "   " --artifact-path ".pipeline/phases/phase-001-align/artifacts/decision-log.md" --artifact-role output

    assert_pipeline_rejected_without_mutation "$artifact_repo" "--artifact-path is required for artifact_recorded" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-role output
    assert_pipeline_rejected_without_mutation "$artifact_repo" "--artifact-path is required for artifact_recorded" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path "" --artifact-role output
    assert_pipeline_rejected_without_mutation "$artifact_repo" "--artifact-path must be a non-empty, non-whitespace string" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path "   " --artifact-role output

    assert_pipeline_rejected_without_mutation "$artifact_repo" "invalid --artifact-role" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path ".pipeline/phases/phase-001-align/artifacts/decision-log.md"
    assert_pipeline_rejected_without_mutation "$artifact_repo" "invalid --artifact-role" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path ".pipeline/phases/phase-001-align/artifacts/decision-log.md" --artifact-role ""
    assert_pipeline_rejected_without_mutation "$artifact_repo" "invalid --artifact-role" \
        --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path ".pipeline/phases/phase-001-align/artifacts/decision-log.md" --artifact-role "   "

    summary_repo="$(create_initialized_pipeline_repo eval4-pipeline-summary)"
    run_update_pipeline_in "$summary_repo" --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$summary_repo" --event phase_added --phase-id phase-002-align --phase-type align --skill-version v2
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$summary_repo" --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    assert_pipeline_rejected_without_mutation "$summary_repo" "--summary is required for superseded" \
        --event superseded --phase-id phase-001-align
    assert_pipeline_rejected_without_mutation "$summary_repo" "--summary is required for superseded" \
        --event superseded --phase-id phase-001-align --summary ""
    assert_pipeline_rejected_without_mutation "$summary_repo" "--summary must be a non-empty, non-whitespace string" \
        --event superseded --phase-id phase-001-align --summary "   "
}

@test "eval 4: batch required fields reject missing empty and whitespace without mutation" {
    local repo

    repo="$(new_test_repo eval4-batch)"
    write_batch_fixture_in "$repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "review",
      "task": "existing review",
      "file_scope": [],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "done",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "converge",
  "current_slice": "",
  "convergence_attempts": 0
}
EOF

    assert_batch_rejected_without_mutation "$repo" "add_slice requires --task and --type" \
        --event add_slice --type implement --scope "scripts/relay"
    assert_batch_rejected_without_mutation "$repo" "add_slice requires --task and --type" \
        --event add_slice --task "" --type implement --scope "scripts/relay"
    assert_batch_rejected_without_mutation "$repo" "--task must be a non-empty, non-whitespace string" \
        --event add_slice --task "   " --type implement --scope "scripts/relay"

    assert_batch_rejected_without_mutation "$repo" "add_slice requires --task and --type" \
        --event add_slice --task "implement relay fixes" --scope "scripts/relay"
    assert_batch_rejected_without_mutation "$repo" "add_slice requires --task and --type" \
        --event add_slice --task "implement relay fixes" --type "" --scope "scripts/relay"
    assert_batch_rejected_without_mutation "$repo" "invalid slice type" \
        --event add_slice --task "implement relay fixes" --type "   " --scope "scripts/relay"
}

@test "eval 4: compose-prompt required fields reject missing empty and whitespace without mutation" {
    local repo
    local header_path
    local prompt_out
    local whitespace_out

    repo="$(new_test_repo eval4-compose)"
    stage_manage_codex_fixture

    header_path="$repo/header.md"
    prompt_out="$repo/out/prompt.md"
    whitespace_out="$repo/   "

    write_fixture "$header_path" <<'EOF'
# Header

Header root: {relay_root}
EOF

    assert_compose_rejected_without_output "$repo" "--header and --out are required" "$prompt_out" \
        --out "$prompt_out"
    assert_compose_rejected_without_output "$repo" "--header and --out are required" "$prompt_out" \
        --header "" --out "$prompt_out"
    assert_compose_rejected_without_output "$repo" "--header must be a non-empty, non-whitespace string" "$prompt_out" \
        --header "   " --out "$prompt_out"

    assert_compose_rejected_without_output "$repo" "--header and --out are required" "$prompt_out" \
        --header "$header_path"
    assert_compose_rejected_without_output "$repo" "--header and --out are required" "$prompt_out" \
        --header "$header_path" --out ""
    assert_compose_rejected_without_output "$repo" "out path must be a non-empty, non-whitespace string" "$whitespace_out" \
        --header "$header_path" --out "   "
}

@test "eval 5: pipeline malformed json corpus fails closed on validate and rebuild" {
    local repo
    local state_file
    local events_file
    local before

    repo="$(create_initialized_pipeline_repo eval5-pipeline)"
    state_file="$(pipeline_file_path "$repo" "state.json")"
    events_file="$(pipeline_file_path "$repo" "events.ndjson")"

    printf '{"pipeline_id":\n' > "$state_file"
    before="$(capture_signatures "$state_file" "$events_file")"

    run_update_pipeline_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"state file"* ]]
    [[ "$output" == *"not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]

    write_fixture "$state_file" <<'EOF'
[]
EOF
    before="$(capture_signatures "$state_file" "$events_file")"

    run_update_pipeline_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"state file must be a JSON object"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]

    repo="$(create_initialized_pipeline_repo eval5-pipeline-ledger)"
    state_file="$(pipeline_file_path "$repo" "state.json")"
    events_file="$(pipeline_file_path "$repo" "events.ndjson")"

    run_update_pipeline_in "$repo" --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    truncate_last_line "$events_file"
    before="$(capture_signatures "$state_file" "$events_file")"

    run_update_pipeline_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:2 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]

    write_fixture "$state_file" <<'EOF'
{"corrupt":true}
EOF
    before="$(capture_signatures "$state_file" "$events_file")"

    run_update_pipeline_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:2 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]

    write_fixture "$events_file" <<'EOF'
{"ts":"2026-03-19T00:00:00Z","event":"init_pipeline","mutation":"init_pipeline","pipeline_id":"mission-001","pipeline_root":".pipeline"}
[]
EOF
    before="$(capture_signatures "$state_file" "$events_file")"

    run_update_pipeline_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:2 must be a JSON object"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]
}

@test "eval 5: batch malformed json corpus fails closed on validate and rebuild" {
    local repo
    local batch_file
    local plan_file
    local events_file
    local before

    repo="$(new_test_repo eval5-batch)"
    batch_file="$(relay_file_path "$repo" ".relay" "batch.json")"
    plan_file="$(relay_file_path "$repo" ".relay" "plan.json")"
    events_file="$(relay_file_path "$repo" ".relay" "events.ndjson")"

    write_batch_fixture_in "$repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "finish implementation",
      "file_scope": ["scripts/relay"],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "implement",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF
    copy_batch_to_plan_in "$repo"

    printf '{"batch_id":\n' > "$batch_file"
    before="$(capture_signatures "$batch_file" "$events_file")"

    run_update_batch_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"batch file"* ]]
    [[ "$output" == *"not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    write_fixture "$batch_file" <<'EOF'
[]
EOF
    before="$(capture_signatures "$batch_file" "$events_file")"

    run_update_batch_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"batch file must be a JSON object"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    repo="$(new_test_repo eval5-batch-ledger)"
    batch_file="$(relay_file_path "$repo" ".relay" "batch.json")"
    plan_file="$(relay_file_path "$repo" ".relay" "plan.json")"
    events_file="$(relay_file_path "$repo" ".relay" "events.ndjson")"
    write_batch_fixture_in "$repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "finish implementation",
      "file_scope": ["scripts/relay"],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "implement",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF
    copy_batch_to_plan_in "$repo"

    run_update_batch_in "$repo" --slice slice-001 --event attempt_started --summary "dispatch"
    [ "$status" -eq 0 ]

    truncate_last_line "$events_file"
    before="$(capture_signatures "$batch_file" "$events_file")"

    run_update_batch_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:1 is not valid JSON"* || "$output" == *"events.ndjson:2 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    write_fixture "$batch_file" <<'EOF'
{"phase":"corrupt","slices":[]}
EOF
    before="$(capture_signatures "$batch_file" "$events_file")"

    run_update_batch_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson"* ]]
    [[ "$output" == *"not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    copy_batch_to_plan_in "$repo"
    write_fixture "$events_file" <<'EOF'
{"ts":"2026-03-19T00:00:00Z","event":"attempt_started","mutation":"attempt_started","slice":"slice-001","summary":"dispatch"}
[]
EOF
    before="$(capture_signatures "$batch_file" "$events_file")"

    run_update_batch_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:2 must be a JSON object"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    write_fixture "$plan_file" <<'EOF'
[]
EOF
    before="$(capture_signatures "$batch_file" "$plan_file" "$events_file")"

    run_update_batch_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"plan file must be a JSON object"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$plan_file" "$events_file")" ]
}

@test "eval 11: pipeline out-of-order events reject without ledger or snapshot mutation" {
    local gate_repo
    local checkpoint_repo
    local execute_repo
    local mission_rel=".pipeline/mission/mission-v001.md"
    local constraints_rel
    local status_rel

    gate_repo="$(create_initialized_pipeline_repo eval11-pipeline-gate)"
    write_fixture "$(repo_path "$gate_repo" "$mission_rel")" <<'EOF'
# Mission

Evaluate invalid next events.
EOF
    run_update_pipeline_in "$gate_repo" --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$gate_repo" --event phase_added --phase-id a1 --phase-type align --skill-version v1
    [ "$status" -eq 0 ]
    prepare_align_gate_inputs_for_phase "$gate_repo" "a1"
    constraints_rel=".pipeline/phases/a1/artifacts/constraints.json"
    run_update_pipeline_in "$gate_repo" --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$gate_repo" --event phase_started --phase-id a1
    [ "$status" -eq 0 ]

    assert_pipeline_rejected_without_mutation "$gate_repo" "must be completed/locked before gate_passed" \
        --event gate_passed --phase-id a1 --summary ready

    checkpoint_repo="$(create_initialized_pipeline_repo eval11-pipeline-checkpoint)"
    write_fixture "$(repo_path "$checkpoint_repo" "$mission_rel")" <<'EOF'
# Mission

Checkpoint ordering.
EOF
    run_update_pipeline_in "$checkpoint_repo" --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$checkpoint_repo" --event phase_added --phase-id a1 --phase-type align --skill-version v1
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$checkpoint_repo" --event phase_added --phase-id x2 --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]
    prepare_align_gate_inputs_for_phase "$checkpoint_repo" "a1"
    constraints_rel=".pipeline/phases/a1/artifacts/constraints.json"
    run_update_pipeline_in "$checkpoint_repo" --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$checkpoint_repo" --event phase_started --phase-id a1
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$checkpoint_repo" --event phase_completed --phase-id a1
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$checkpoint_repo" --event gate_passed --phase-id a1 --summary ready
    [ "$status" -eq 0 ]
    status_rel=".pipeline/phases/x2/runtime/adapter-status.json"
    write_pipeline_adapter_status "$(repo_path "$checkpoint_repo" "$status_rel")" "x2" "reviewing" "2100-01-01T00:00:00Z" 3 1

    assert_pipeline_rejected_without_mutation "$checkpoint_repo" "must be in_progress before child_checkpoint" \
        --event child_checkpoint --phase-id x2

    execute_repo="$(clone_test_repo "$checkpoint_repo")"
    run_update_pipeline_in "$execute_repo" --event phase_started --phase-id x2
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$execute_repo" --event child_checkpoint --phase-id x2
    [ "$status" -eq 0 ]

    assert_pipeline_rejected_without_mutation "$execute_repo" "child workflow status is reviewing, not terminal" \
        --event phase_completed --phase-id x2
}

@test "eval 11: batch out-of-order events reject without ledger or snapshot mutation" {
    local converge_repo
    local done_repo

    converge_repo="$(new_test_repo eval11-batch-converge)"
    write_batch_fixture_in "$converge_repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "finish implementation",
      "file_scope": ["scripts/relay"],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    },
    {
      "id": "slice-002",
      "type": "converge",
      "task": "assess convergence",
      "file_scope": [],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "converge",
  "current_slice": "",
  "convergence_attempts": 0
}
EOF

    assert_batch_rejected_without_mutation "$converge_repo" "converge_complete rejected; slice slice-001 is still pending" \
        --event converge_complete --summary blocked

    done_repo="$(new_test_repo eval11-batch-done)"
    write_batch_fixture_in "$done_repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "already complete",
      "file_scope": ["scripts/relay"],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "done",
      "impl_attempts": 1,
      "review_rejections": 0
    }
  ],
  "phase": "converge",
  "current_slice": "",
  "convergence_attempts": 0
}
EOF

    assert_batch_rejected_without_mutation "$done_repo" "attempt_started rejected; slice slice-001 is already done" \
        --slice slice-001 --event attempt_started --summary "dispatch"
    assert_batch_rejected_without_mutation "$done_repo" "review_clean rejected; slice slice-001 is already done" \
        --slice slice-001 --event review_clean --summary CLEAN
}

@test "eval 15: truncated final pipeline ledger line fails closed then recovers" {
    local repo
    local state_file
    local events_file
    local expected_state
    local before

    repo="$(create_initialized_pipeline_repo eval15-pipeline)"
    state_file="$(pipeline_file_path "$repo" "state.json")"
    events_file="$(pipeline_file_path "$repo" "events.ndjson")"

    run_update_pipeline_in "$repo" --event phase_added --phase-id a1 --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    expected_state="$repo/expected-recovered-state.json"
    cp "$state_file" "$expected_state"

    run_update_pipeline_in "$repo" --event phase_started --phase-id a1
    [ "$status" -eq 0 ]

    truncate_last_line "$events_file"
    before="$(capture_signatures "$state_file" "$events_file")"

    run_update_pipeline_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:3 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]

    before="$(capture_signatures "$state_file" "$events_file")"
    run_update_pipeline_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:3 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$state_file" "$events_file")" ]

    drop_last_line "$events_file"

    run_update_pipeline_in "$repo" --rebuild
    [ "$status" -eq 0 ]
    cmp -s "$expected_state" "$state_file"

    run_update_pipeline_in "$repo" --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "eval 15: truncated final batch ledger line fails closed then recovers" {
    local repo
    local batch_file
    local events_file
    local expected_batch
    local before

    repo="$(new_test_repo eval15-batch)"
    batch_file="$(relay_file_path "$repo" ".relay" "batch.json")"
    events_file="$(relay_file_path "$repo" ".relay" "events.ndjson")"

    write_batch_fixture_in "$repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "finish implementation",
      "file_scope": ["scripts/relay"],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "implement",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF
    copy_batch_to_plan_in "$repo"

    expected_batch="$repo/expected-recovered-batch.json"
    cp "$batch_file" "$expected_batch"

    run_update_batch_in "$repo" --slice slice-001 --event attempt_started --summary "dispatch"
    [ "$status" -eq 0 ]

    truncate_last_line "$events_file"
    before="$(capture_signatures "$batch_file" "$events_file")"

    run_update_batch_in "$repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:1 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    before="$(capture_signatures "$batch_file" "$events_file")"
    run_update_batch_in "$repo" --rebuild
    [ "$status" -ne 0 ]
    [[ "$output" == *"events.ndjson:1 is not valid JSON"* ]]
    [ "$before" = "$(capture_signatures "$batch_file" "$events_file")" ]

    drop_last_line "$events_file"

    run_update_batch_in "$repo" --rebuild
    [ "$status" -eq 0 ]
    assert_json_files_equal "$expected_batch" "$batch_file"

    run_update_batch_in "$repo" --validate
    [ "$status" -eq 0 ]
    [ "$output" = "batch.json: consistent" ]
}

@test "eval 7: complex pipeline replay is byte-identical and idempotent" {
    local repo
    local mission_rel=".pipeline/mission/mission-v001.md"
    local baseline_state
    local status_rel=".pipeline/phases/x/runtime/adapter-status.json"

    repo="$(create_initialized_pipeline_repo eval7-pipeline m)"
    write_fixture "$(repo_path "$repo" "$mission_rel")" <<'EOF'
# Mission

Drive a complex deterministic pipeline history.
EOF

    run_update_pipeline_in "$repo" --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --event phase_added --phase-id t --phase-type triage --skill-version 1
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_added --phase-id a --phase-type align --skill-version 2
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_added --phase-id b --phase-type align --skill-version 3
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_added --phase-id c --phase-type align --skill-version 4
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_added --phase-id x --phase-type execute --skill-version 5 --adapter-id r --adapter-version 1
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --event phase_started --phase-id t
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_completed --phase-id t
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --event phase_started --phase-id a
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event superseded --phase-id a --summary r
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --event phase_started --phase-id b
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_completed --phase-id b
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event gate_failed --phase-id b --summary b
    [ "$status" -eq 0 ]

    prepare_align_gate_inputs_for_phase "$repo" "c"
    run_update_pipeline_in "$repo" --event constraint_set_activated --constraint-path ".pipeline/phases/c/artifacts/constraints.json"
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_started --phase-id c
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event phase_completed --phase-id c
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event gate_passed --phase-id c --summary p
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --event phase_started --phase-id x
    [ "$status" -eq 0 ]

    write_pipeline_adapter_status "$(repo_path "$repo" "$status_rel")" "x" "reviewing" "2100-01-01T00:00:00Z" 3 1
    run_update_pipeline_in "$repo" --event child_checkpoint --phase-id x
    [ "$status" -eq 0 ]

    write_pipeline_adapter_status "$(repo_path "$repo" "$status_rel")" "x" "reviewing" "2100-01-01T00:05:00Z" 3 2
    run_update_pipeline_in "$repo" --event child_checkpoint --phase-id x
    [ "$status" -eq 0 ]

    write_pipeline_adapter_status "$(repo_path "$repo" "$status_rel")" "x" "complete" "2100-01-01T00:10:00Z" 3 3
    run_update_pipeline_in "$repo" --event child_checkpoint --phase-id x
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --event phase_completed --phase-id x
    [ "$status" -eq 0 ]
    run_update_pipeline_in "$repo" --event pipeline_completed
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$repo" --validate
    [ "$status" -eq 0 ]

    run read_ndjson_file_value "$(pipeline_file_path "$repo" "events.ndjson")" "events[-1]['metrics']['epoch_resets']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_ndjson_file_value "$(pipeline_file_path "$repo" "events.ndjson")" "events[-1]['metrics']['gate_failures']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    baseline_state="$repo/baseline-state.json"
    cp "$(pipeline_file_path "$repo" "state.json")" "$baseline_state"
    printf 'not valid json\n' > "$(pipeline_file_path "$repo" "state.json")"

    run_update_pipeline_in "$repo" --rebuild
    [ "$status" -eq 0 ]
    cmp -s "$baseline_state" "$(pipeline_file_path "$repo" "state.json")"

    run_update_pipeline_in "$repo" --rebuild
    [ "$status" -eq 0 ]
    cmp -s "$baseline_state" "$(pipeline_file_path "$repo" "state.json")"

    run_update_pipeline_in "$repo" --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "eval 13: pipeline rebuild recovers from crash after ledger append" {
    local crash_repo
    local expected_repo
    local state_before_crash
    local events_before_crash

    crash_repo="$(create_initialized_pipeline_repo eval13-crash)"
    run_update_pipeline_in "$crash_repo" --event phase_added --phase-id a1 --phase-type align --skill-version v1
    [ "$status" -eq 0 ]
    inject_crash_after_pipeline_append "$crash_repo/scripts/pipeline/update-pipeline.sh"

    state_before_crash="$(file_signature "$(pipeline_file_path "$crash_repo" "state.json")")"
    events_before_crash="$(file_signature "$(pipeline_file_path "$crash_repo" "events.ndjson")")"

    run_crashy_update_pipeline_in "$crash_repo" --event phase_started --phase-id a1
    [ "$status" -eq 99 ]
    [[ "$output" == *"CRASH: injected after append_event"* ]]

    [ "$state_before_crash" = "$(file_signature "$(pipeline_file_path "$crash_repo" "state.json")")" ]
    [ "$events_before_crash" != "$(file_signature "$(pipeline_file_path "$crash_repo" "events.ndjson")")" ]

    run_update_pipeline_in "$crash_repo" --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"does not match replay of events.ndjson"* ]]

    expected_repo="$(clone_test_repo "$crash_repo")"
    run_update_pipeline_in "$expected_repo" --rebuild
    [ "$status" -eq 0 ]

    run_update_pipeline_in "$crash_repo" --rebuild
    [ "$status" -eq 0 ]
    cmp -s "$(pipeline_file_path "$expected_repo" "state.json")" "$(pipeline_file_path "$crash_repo" "state.json")"

    run_update_pipeline_in "$crash_repo" --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "eval 14: batch rebuild recovers from crash after ledger append" {
    local crash_repo
    local expected_repo
    local batch_file
    local events_file
    local batch_before_crash
    local events_before_crash

    crash_repo="$(new_test_repo eval14-crash)"
    batch_file="$(relay_file_path "$crash_repo" ".relay" "batch.json")"
    events_file="$(relay_file_path "$crash_repo" ".relay" "events.ndjson")"

    write_batch_fixture_in "$crash_repo" <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "finish implementation",
      "file_scope": ["scripts/relay"],
      "domain_skills": [],
      "verification_commands": [],
      "success_criteria": "",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "implement",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF
    copy_batch_to_plan_in "$crash_repo"
    inject_crash_after_batch_append "$crash_repo/scripts/relay/update-batch.sh"

    batch_before_crash="$(file_signature "$batch_file")"
    events_before_crash="$(file_signature "$events_file")"

    run_crashy_update_batch_in "$crash_repo" --slice slice-001 --event attempt_started --summary "dispatch"
    [ "$status" -eq 99 ]
    [[ "$output" == *"CRASH: injected after append_event"* ]]

    [ "$batch_before_crash" = "$(file_signature "$batch_file")" ]
    [ "$events_before_crash" != "$(file_signature "$events_file")" ]

    run read_json_file_value "$batch_file" "payload['slices'][0]['impl_attempts']"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run read_ndjson_file_value "$events_file" "events[-1]['mutation']"
    [ "$status" -eq 0 ]
    [ "$output" = "attempt_started" ]

    expected_repo="$(clone_test_repo "$crash_repo")"
    run_update_batch_in "$expected_repo" --rebuild
    [ "$status" -eq 0 ]

    run_update_batch_in "$crash_repo" --rebuild
    [ "$status" -eq 0 ]
    assert_json_files_equal "$(relay_file_path "$expected_repo" ".relay" "batch.json")" "$batch_file"

    run read_json_file_value "$batch_file" "payload['slices'][0]['impl_attempts']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_json_file_value "$batch_file" "payload['current_slice']"
    [ "$status" -eq 0 ]
    [ "$output" = "slice-001" ]

    run_update_batch_in "$crash_repo" --validate
    [ "$status" -eq 0 ]
    [ "$output" = "batch.json: consistent" ]
}

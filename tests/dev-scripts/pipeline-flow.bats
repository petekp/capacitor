#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    TEST_HOME="$TEST_DIR/home"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p \
        "$TEST_DIR/scripts/pipeline" \
        "$TEST_DIR/scripts/relay" \
        "$TEST_HOME/.claude/skills/manage-codex/references"

    cp "$PROJECT_ROOT/scripts/pipeline/update-pipeline.sh" "$TEST_DIR/scripts/pipeline/"
    cp "$PROJECT_ROOT/scripts/relay/compose-prompt.sh" "$TEST_DIR/scripts/relay/"
    cp "$PROJECT_ROOT/scripts/relay/update-batch.sh" "$TEST_DIR/scripts/relay/"

    chmod +x \
        "$TEST_DIR/scripts/pipeline/update-pipeline.sh" \
        "$TEST_DIR/scripts/relay/compose-prompt.sh" \
        "$TEST_DIR/scripts/relay/update-batch.sh"

    git -C "$TEST_DIR" init -q
}

teardown() {
    rm -rf "$TEST_DIR"
}

pipeline_file_path() {
    local root="${1:-$TEST_DIR/.pipeline}"
    local name="$2"
    printf '%s/%s\n' "${root%/}" "$name"
}

relay_file_path() {
    local root="$1"
    local name="$2"
    printf '%s/%s\n' "${root%/}" "$name"
}

write_fixture() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path"
}

file_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

read_json_file_value() {
    local path="$1"
    local expr="$2"
    python3 - "$path" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path) as fh:
    payload = json.load(fh)

value = eval(expr, {"__builtins__": {}}, {"payload": payload})
if isinstance(value, list):
    for item in value:
        print(item)
elif isinstance(value, dict):
    print(json.dumps(value, sort_keys=True))
elif value is None:
    print("")
else:
    print(value)
PY
}

read_ndjson_file_value() {
    local path="$1"
    local expr="$2"
    python3 - "$path" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
events = []
with open(path) as fh:
    for line in fh:
        line = line.strip()
        if line:
            events.append(json.loads(line))

value = eval(expr, {"__builtins__": {}}, {"events": events})
if isinstance(value, list):
    for item in value:
        print(item)
elif isinstance(value, dict):
    print(json.dumps(value, sort_keys=True))
elif value is None:
    print("")
else:
    print(value)
PY
}

read_state_value() {
    local expr="$1"
    python3 - "$(pipeline_file_path "$TEST_DIR/.pipeline" "state.json")" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path) as fh:
    state = json.load(fh)

value = eval(expr, {"__builtins__": {}}, {"state": state})
if isinstance(value, list):
    for item in value:
        print(item)
elif isinstance(value, dict):
    print(json.dumps(value, sort_keys=True))
elif value is None:
    print("")
else:
    print(value)
PY
}

read_pipeline_events_value() {
    local expr="$1"
    read_ndjson_file_value "$(pipeline_file_path "$TEST_DIR/.pipeline" "events.ndjson")" "$expr"
}

read_batch_value() {
    local expr="$1"
    local root="$2"
    python3 - "$(relay_file_path "$root" "batch.json")" "$expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path) as fh:
    batch = json.load(fh)

value = eval(expr, {"__builtins__": {}}, {"batch": batch})
if isinstance(value, list):
    for item in value:
        print(item)
elif isinstance(value, dict):
    print(json.dumps(value, sort_keys=True))
elif value is None:
    print("")
else:
    print(value)
PY
}

read_relay_events_value() {
    local expr="$1"
    local root="$2"
    read_ndjson_file_value "$(relay_file_path "$root" "events.ndjson")" "$expr"
}

write_valid_constraints_json() {
    local path="$1"
    write_fixture "$path" <<'EOF'
{
  "schema_version": 1,
  "allowed_paths": [
    "tests/dev-scripts/pipeline-flow.bats"
  ],
  "interface_changes": [
    "Add deterministic pipeline coverage"
  ],
  "verification_commands": [
    "bats tests/dev-scripts/pipeline-flow.bats"
  ],
  "non_goals": [
    "No deferred v2 child features"
  ],
  "open_questions": []
}
EOF
}

write_relay_plan_fixture() {
    local path="$1"
    write_fixture "$path" <<'EOF'
{
  "batch_id": "e2e-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "Close the deterministic execute loop",
      "file_scope": ["tests/dev-scripts/pipeline-flow.bats"],
      "domain_skills": [],
      "verification_commands": ["bats tests/dev-scripts/pipeline-flow.bats"],
      "success_criteria": "Rooted relay flow stays deterministic",
      "status": "pending",
      "impl_attempts": 0,
      "review_rejections": 0
    }
  ],
  "phase": "plan",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF
}

stage_manage_codex_fixture() {
    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/implement-template.md" <<'EOF'
# Implement Template
Write outputs under {relay_root}.
EOF

    write_fixture "$TEST_HOME/.claude/skills/manage-codex/references/relay-protocol.md" <<'EOF'
# Relay Protocol
Read and write relay state only inside {relay_root}.
EOF
}

write_adapter_status_json() {
    local path="$1"
    local phase_id="$2"
    local relay_root_rel="$3"
    local handoff_rel="$4"
    local handoff_hash="$5"
    local review_rel="$6"
    local review_hash="$7"
    local checkpoint_at="$8"

    write_fixture "$path" <<EOF
{
  "schema_version": 2,
  "adapter_id": "manage-codex-relay",
  "phase_id": "$phase_id",
  "pipeline_root": ".pipeline",
  "relay_root": "$relay_root_rel",
  "status": "complete",
  "progress_summary": "Slice closed cleanly.",
  "current_child_phase": "complete",
  "current_slice_id": "slice-001",
  "current_operation": "Converged e2e-batch",
  "counts": {
    "total_slices": 1,
    "completed_slices": 1,
    "review_rejections": 0,
    "convergence_attempts": 0,
    "elapsed_seconds": 12,
    "retry_count": 0
  },
  "latest_artifacts": {
    "handoff_path": "$handoff_rel",
    "handoff_sha256": "$handoff_hash",
    "review_findings_path": "$review_rel",
    "review_findings_sha256": "$review_hash"
  },
  "last_checkpoint_at": "$checkpoint_at",
  "verdict": {
    "status": "clean",
    "summary": "All slices complete."
  }
}
EOF
}

run_update_pipeline() {
    run env HOME="$TEST_HOME" TEST_DIR="$TEST_DIR" /bin/bash -lc 'cd "$TEST_DIR" && ./scripts/pipeline/update-pipeline.sh "$@"' bash "$@"
}

run_update_batch() {
    run env HOME="$TEST_HOME" TEST_DIR="$TEST_DIR" /bin/bash -lc 'cd "$TEST_DIR" && ./scripts/relay/update-batch.sh "$@"' bash "$@"
}

run_compose_prompt() {
    run env HOME="$TEST_HOME" TEST_DIR="$TEST_DIR" /bin/bash -lc 'cd "$TEST_DIR" && ./scripts/relay/compose-prompt.sh "$@"' bash "$@"
}

@test "full deterministic pipeline flow stays rooted compact and rebuildable" {
    local mission_id="mission-e2e"
    local triage_phase="triage-001"
    local align_phase="align-001"
    local execute_phase="execute-001"
    local mission_rel=".pipeline/mission/mission-v001.md"
    local spec_rel=".pipeline/phases/$align_phase/artifacts/execution-spec.md"
    local plan_rel=".pipeline/phases/$align_phase/artifacts/verification-plan.md"
    local constraints_rel=".pipeline/phases/$align_phase/artifacts/constraints.json"
    local relay_root_rel=".pipeline/phases/$execute_phase/runtime/relay"
    local relay_root_abs="$TEST_DIR/$relay_root_rel"
    local status_rel=".pipeline/phases/$execute_phase/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    local prompt_header="$TEST_DIR/prompt-header.md"
    local prompt_out="$relay_root_abs/prompt.md"
    local relay_plan="$relay_root_abs/plan.json"
    local relay_batch="$relay_root_abs/batch.json"
    local handoff_rel="$relay_root_rel/handoffs/handoff-slice-001.md"
    local handoff_abs="$TEST_DIR/$handoff_rel"
    local review_rel="$relay_root_rel/review-findings/review-findings-slice-001.md"
    local review_abs="$TEST_DIR/$review_rel"
    local baseline_state="$TEST_DIR/baseline-state.json"

    run_update_pipeline --event init_pipeline --mission-id "$mission_id"
    [ "$status" -eq 0 ]

    write_fixture "$TEST_DIR/$mission_rel" <<'EOF'
# Mission
Ship the deterministic pipeline.
EOF

    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$triage_phase" --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$align_phase" --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$triage_phase"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id "$triage_phase"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$align_phase"
    [ "$status" -eq 0 ]

    write_fixture "$TEST_DIR/$spec_rel" <<'EOF'
# Execute
Keep the child flow deterministic.
EOF

    write_fixture "$TEST_DIR/$plan_rel" <<'EOF'
# Verify
- bats tests/dev-scripts/pipeline-flow.bats
EOF

    write_valid_constraints_json "$TEST_DIR/$constraints_rel"

    run_update_pipeline --event artifact_recorded --phase-id "$align_phase" --artifact-id execution-spec --artifact-path "$spec_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event artifact_recorded --phase-id "$align_phase" --artifact-id verification-plan --artifact-path "$plan_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id "$align_phase"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$execute_phase" --phase-type execute --skill-version v1 --adapter-id manage-codex-relay --adapter-version v1
    [ "$status" -eq 0 ]

    run read_state_value "state['phases'][2]['adapter']['relay_root']"
    [ "$status" -eq 0 ]
    [ "$output" = "$relay_root_rel" ]

    run read_state_value "state['phases'][2]['adapter']['status_path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$status_rel" ]

    run_update_pipeline --event phase_started --phase-id "$execute_phase"
    [ "$status" -eq 1 ]
    [[ "$output" == *"predecessor gate must pass before execute $execute_phase can start"* ]]

    run_update_pipeline --event gate_passed --phase-id "$align_phase" --summary "Ready."
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$execute_phase"
    [ "$status" -eq 0 ]

    stage_manage_codex_fixture

    write_fixture "$prompt_header" <<'EOF'
# Execute Header
Relay root: {relay_root}
EOF

    run_compose_prompt --header "$prompt_header" --template implement --root "$relay_root_abs" --out "$prompt_out"
    [ "$status" -eq 0 ]
    [ -f "$prompt_out" ]
    grep -Fq "Relay root: $relay_root_abs" "$prompt_out"
    grep -Fq "Write outputs under $relay_root_abs." "$prompt_out"
    grep -Fq "Read and write relay state only inside $relay_root_abs." "$prompt_out"

    run grep -F "{relay_root}" "$prompt_out"
    [ "$status" -eq 1 ]

    write_relay_plan_fixture "$relay_plan"
    cp "$relay_plan" "$relay_batch"

    write_fixture "$handoff_abs" <<'EOF'
### Files Changed
tests/dev-scripts/pipeline-flow.bats

### Tests Run
bats tests/dev-scripts/pipeline-flow.bats

### Completion Claim
COMPLETE
EOF

    write_fixture "$review_abs" <<'EOF'
# Review Findings
CLEAN
EOF

    run_update_batch --root "$relay_root_rel" --slice slice-001 --event attempt_started --summary "Dispatch worker." --handoff "$handoff_abs"
    [ "$status" -eq 0 ]

    run_update_batch --root "$relay_root_rel" --slice slice-001 --event impl_dispatched --summary "Focused verification ran."
    [ "$status" -eq 0 ]

    run_update_batch --root "$relay_root_rel" --slice slice-001 --event review_clean --summary "CLEAN"
    [ "$status" -eq 0 ]

    run_update_batch --root "$relay_root_rel" --event converge_complete --summary "Converged."
    [ "$status" -eq 0 ]

    [ -f "$relay_root_abs/events.ndjson" ]
    [ -f "$relay_root_abs/archive/e2e-batch-slice-001-attempt_started-1.md" ]
    [ ! -e "$TEST_DIR/.relay" ]
    [ ! -f "$TEST_DIR/.pipeline/plan.json" ]

    run read_batch_value "batch['phase']" "$relay_root_abs"
    [ "$status" -eq 0 ]
    [ "$output" = "complete" ]

    run read_batch_value "batch['current_slice']" "$relay_root_abs"
    [ "$status" -eq 0 ]
    [ "$output" = "" ]

    run read_batch_value "batch['slices'][0]['status']" "$relay_root_abs"
    [ "$status" -eq 0 ]
    [ "$output" = "done" ]

    run read_batch_value "batch['slices'][0]['impl_attempts']" "$relay_root_abs"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_batch_value "batch['slices'][0]['review']" "$relay_root_abs"
    [ "$status" -eq 0 ]
    [ "$output" = "CLEAN" ]

    run read_relay_events_value "[event['mutation'] for event in events]" "$relay_root_abs"
    [ "$status" -eq 0 ]
    [ "$output" = $'attempt_started\nimpl_dispatched\nreview_clean\nconverge_complete' ]

    run_update_batch --root "$relay_root_rel" --validate
    [ "$status" -eq 0 ]
    [ "$output" = "batch.json: consistent" ]

    write_adapter_status_json \
        "$status_abs" \
        "$execute_phase" \
        "$relay_root_rel" \
        "$handoff_rel" \
        "$(file_sha256 "$handoff_abs")" \
        "$review_rel" \
        "$(file_sha256 "$review_abs")" \
        "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id "$execute_phase"
    [ "$status" -eq 0 ]

    run read_state_value "state['child_workflow'] == {'status': 'complete', 'last_checkpoint_at': '2100-01-01T00:00:00Z', 'phase_id': '$execute_phase', 'counts': {'total_slices': 1}}"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "'relay_root' in state['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "state['phases'][2]['child_workflow']['current_operation']"
    [ "$status" -eq 0 ]
    [ "$output" = "Converged e2e-batch" ]

    run read_state_value "state['phases'][2]['child_workflow']['verdict']"
    [ "$status" -eq 0 ]
    [ "$output" = "clean" ]

    run read_state_value "'counts' in state['phases'][2]['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "state['phases'][2]['child_workflow'] != state['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_pipeline_events_value "events[-1]['reconciled_forward']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run_update_pipeline --event phase_completed --phase-id "$execute_phase"
    [ "$status" -eq 0 ]

    run_update_pipeline --event pipeline_completed
    [ "$status" -eq 0 ]

    run read_state_value "state['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "complete" ]

    run read_state_value "state['current_phase_id'] is None"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "state['phases'][2]['child_workflow']['counts']['total_slices']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_pipeline_events_value "events[-2]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "pipeline_completed" ]

    run read_pipeline_events_value "events[-1]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "pipeline_retrospective" ]

    run read_pipeline_events_value "events[-1]['metrics']['total_phases']"
    [ "$status" -eq 0 ]
    [ "$output" = "3" ]

    run read_pipeline_events_value "events[-1]['metrics']['epoch_resets']"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run read_pipeline_events_value "events[-1]['metrics']['gate_failures']"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run read_pipeline_events_value "events[-1]['metrics']['rework_phases']"
    [ "$status" -eq 0 ]
    [ "$output" = "0" ]

    run read_pipeline_events_value "events[-1]['metrics']['execute_slice_counts']['$execute_phase']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run env TEST_DIR="$TEST_DIR" python3 -c "import os; print(os.path.getsize(os.path.join(os.environ['TEST_DIR'], '.pipeline', 'state.json')) < 2048)"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    cp "$TEST_DIR/.pipeline/state.json" "$baseline_state"
    printf 'not valid json\n' > "$TEST_DIR/.pipeline/state.json"

    run_update_pipeline --rebuild
    [ "$status" -eq 0 ]

    cmp -s "$baseline_state" "$TEST_DIR/.pipeline/state.json"

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

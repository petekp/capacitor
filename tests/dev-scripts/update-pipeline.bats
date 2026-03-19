#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/pipeline"
    cp "$PROJECT_ROOT/scripts/pipeline/update-pipeline.sh" "$TEST_DIR/scripts/pipeline/"
    chmod +x "$TEST_DIR/scripts/pipeline/update-pipeline.sh"

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
elif value is None:
    print("")
else:
    print(value)
PY
}

write_valid_constraints_json() {
    local path="$1"
    cat <<'EOF' > "$path"
{
  "schema_version": 1,
  "allowed_paths": [
    "scripts/pipeline/update-pipeline.sh",
    "tests/dev-scripts/update-pipeline.bats"
  ],
  "interface_changes": [
    "Add gate events to pipeline mutator"
  ],
  "verification_commands": [
    "bats tests/dev-scripts/update-pipeline.bats"
  ],
  "non_goals": [
    "No Rust or Swift runtime changes"
  ],
  "open_questions": []
}
EOF
}

record_align_gate_artifacts() {
    local phase_id="$1"
    local spec_rel="e.md"
    local spec_abs="$TEST_DIR/$spec_rel"
    local plan_rel="v.md"
    local plan_abs="$TEST_DIR/$plan_rel"

    cat <<EOF > "$spec_abs"
# Execution Spec

Keep $phase_id ready for deterministic execute handoff.
EOF

    cat <<'EOF' > "$plan_abs"
# Verification Plan

- bats tests/dev-scripts/update-pipeline.bats
EOF

    run_update_pipeline --event artifact_recorded --phase-id "$phase_id" --artifact-id execution-spec --artifact-path "$spec_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event artifact_recorded --phase-id "$phase_id" --artifact-id verification-plan --artifact-path "$plan_rel" --artifact-role output
    [ "$status" -eq 0 ]
}

write_adapter_status_json() {
    local path="$1"
    local phase_id="$2"
    local status="$3"
    local checkpoint_at="$4"

    cat <<EOF > "$path"
{
  "schema_version": 2,
  "adapter_id": "manage-codex-relay",
  "phase_id": "$phase_id",
  "pipeline_root": ".pipeline",
  "relay_root": ".pipeline/phases/$phase_id/runtime/relay",
  "status": "$status",
  "progress_summary": "Reviewing slice-002 of 4; last review was CLEAN.",
  "current_child_phase": "review",
  "current_slice_id": "slice-002",
  "current_operation": "Reviewing slice-002",
  "counts": {
    "total_slices": 4,
    "completed_slices": 1,
    "review_rejections": 0,
    "convergence_attempts": 0,
    "elapsed_seconds": 95,
    "retry_count": 2
  },
  "latest_artifacts": {
    "handoff_path": ".pipeline/phases/$phase_id/runtime/relay/handoffs/handoff-slice-002.md",
    "handoff_sha256": "sha256:handoff",
    "review_findings_path": ".pipeline/phases/$phase_id/runtime/relay/review-findings/review-findings-slice-002.md",
    "review_findings_sha256": "sha256:review"
  },
  "last_checkpoint_at": "$checkpoint_at",
  "verdict": null
}
EOF
}

write_adversarial_adapter_status_json() {
    local path="$1"
    local phase_id="$2"
    local status="$3"
    local checkpoint_at="$4"

    python3 - "$path" "$phase_id" "$status" "$checkpoint_at" <<'PY'
import json
import sys

path, phase_id, status, checkpoint_at = sys.argv[1:5]
payload = {
    "schema_version": 2,
    "adapter_id": "manage-codex-relay",
    "phase_id": phase_id,
    "pipeline_root": ".pipeline",
    "relay_root": f".pipeline/phases/{phase_id}/runtime/relay",
    "status": status,
    "progress_summary": "P" * 2000,
    "current_child_phase": "review-" + ("C" * 120),
    "current_slice_id": "slice-" + ("S" * 160),
    "current_operation": "O" * 200,
    "counts": {
        "total_slices": 4,
        "completed_slices": 1,
        "review_rejections": 0,
        "convergence_attempts": 0,
        "elapsed_seconds": 95,
        "retry_count": 2,
    },
    "latest_artifacts": {
        "handoff_path": f".pipeline/phases/{phase_id}/runtime/relay/handoffs/handoff-slice-002.md",
        "handoff_sha256": "sha256:handoff",
        "review_findings_path": f".pipeline/phases/{phase_id}/runtime/relay/review-findings/review-findings-slice-002.md",
        "review_findings_sha256": "sha256:review",
    },
    "last_checkpoint_at": checkpoint_at,
    "verdict": "V" * 200,
}

with open(path, "w") as fh:
    json.dump(payload, fh, indent=2)
    fh.write("\n")
PY
}

read_state_value() {
    local expr="$1"
    local root="${2:-$TEST_DIR/.pipeline}"
    python3 - "$(pipeline_file_path "$root" "state.json")" "$expr" <<'PY'
import json
import sys

state_path, expr = sys.argv[1], sys.argv[2]
with open(state_path) as fh:
    state = json.load(fh)

value = eval(expr, {"__builtins__": {}}, {"state": state})
if isinstance(value, list):
    for item in value:
        print(item)
elif value is None:
    print("")
else:
    print(value)
PY
}

read_events_value() {
    local expr="$1"
    local root="${2:-$TEST_DIR/.pipeline}"
    python3 - "$(pipeline_file_path "$root" "events.ndjson")" "$expr" <<'PY'
import json
import sys

events_path, expr = sys.argv[1], sys.argv[2]
events = []
with open(events_path) as fh:
    for line in fh:
        line = line.strip()
        if line:
            events.append(json.loads(line))

value = eval(expr, {"__builtins__": {}}, {"events": events})
if isinstance(value, list):
    for item in value:
        print(item)
elif value is None:
    print("")
else:
    print(value)
PY
}

run_update_pipeline() {
    run env TEST_DIR="$TEST_DIR" /bin/bash -lc 'cd "$TEST_DIR" && ./scripts/pipeline/update-pipeline.sh "$@"' bash "$@"
}

@test "init_pipeline creates rooted state and ledger without a pipeline plan" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    [ -f "$TEST_DIR/.pipeline/state.json" ]
    [ -f "$TEST_DIR/.pipeline/events.ndjson" ]
    [ -d "$TEST_DIR/.pipeline/mission" ]
    [ ! -f "$TEST_DIR/.pipeline/plan.json" ]

    run read_state_value "state['pipeline_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "mission-001" ]

    run read_state_value "state['pipeline_root']"
    [ "$status" -eq 0 ]
    [ "$output" = ".pipeline" ]

    run read_state_value "'repo_root' in state"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "state['updated_at'].endswith('Z') and 'T' in state['updated_at']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "{key: value for key, value in state.items() if key != 'updated_at'} == {'pipeline_id': 'mission-001', 'pipeline_root': '.pipeline', 'status': 'active', 'active_epoch_id': 'epoch-001', 'current_phase_id': None, 'phases': [], 'latest_resume': None, 'child_workflow': None, 'automatic_resume': {'blocked': False}}"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_events_value "events[0]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "init_pipeline" ]
}

@test "phase_added requires skill-version" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage
    [ "$status" -eq 1 ]
    [[ "$output" == *"--skill-version is required for phase_added"* ]]
}

@test "phase_added creates phase directories and execute adapter paths relative to repo root" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-execute --phase-type execute --skill-version v1
    [ "$status" -eq 1 ]
    [[ "$output" == *"--adapter-id is required for execute phase_added"* ]]

    run_update_pipeline --event phase_added --phase-id phase-001-execute --phase-type execute --skill-version v1 --adapter-id manage-codex-relay
    [ "$status" -eq 1 ]
    [[ "$output" == *"--adapter-version is required for execute phase_added"* ]]

    run_update_pipeline --event phase_added --phase-id phase-001-execute --phase-type execute --skill-version v1 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    [ -d "$TEST_DIR/.pipeline/phases/phase-001-execute/artifacts" ]
    [ -d "$TEST_DIR/.pipeline/phases/phase-001-execute/runtime" ]
    [ -d "$TEST_DIR/.pipeline/phases/phase-001-execute/runtime/relay" ]

    run read_state_value "state['phases'][0]['phase_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "phase-001-execute" ]

    run read_state_value "state['phases'][0]['skill_version']"
    [ "$status" -eq 0 ]
    [ "$output" = "v1" ]

    run read_state_value "state['phases'][0]['adapter']['adapter_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "manage-codex-relay" ]

    run read_state_value "state['phases'][0]['adapter']['adapter_version']"
    [ "$status" -eq 0 ]
    [ "$output" = "adapter-v2" ]

    run read_state_value "state['phases'][0]['adapter']['relay_root']"
    [ "$status" -eq 0 ]
    [ "$output" = ".pipeline/phases/phase-001-execute/runtime/relay" ]

    run read_state_value "state['phases'][0]['adapter']['status_path']"
    [ "$status" -eq 0 ]
    [ "$output" = ".pipeline/phases/phase-001-execute/runtime/adapter-status.json" ]

    run read_state_value "state['phases'][0] == {'phase_id': 'phase-001-execute', 'phase_type': 'execute', 'skill_version': 'v1', 'status': 'pending', 'lock_state': 'unlocked', 'adapter': {'adapter_id': 'manage-codex-relay', 'adapter_version': 'adapter-v2', 'relay_root': '.pipeline/phases/phase-001-execute/runtime/relay', 'status_path': '.pipeline/phases/phase-001-execute/runtime/adapter-status.json'}}"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run env TEST_DIR="$TEST_DIR" python3 -c "import os; print(os.path.getsize(os.path.join(os.environ['TEST_DIR'], '.pipeline', 'state.json')) < 2048)"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
}

@test "phase_started enforces a single in-progress phase" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-align --phase-type align --skill-version v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run read_state_value "state['current_phase_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "phase-001-triage" ]

    run read_state_value "[phase['status'] for phase in state['phases']]"
    [ "$status" -eq 0 ]
    [ "$output" = $'in_progress\npending' ]

    run_update_pipeline --event phase_started --phase-id phase-002-align
    [ "$status" -eq 1 ]
    [[ "$output" == *"already in_progress"* ]]

    run read_state_value "state['current_phase_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "phase-001-triage" ]
}

@test "phase_started rejects an already in-progress phase" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-triage
    [ "$status" -eq 1 ]
    [ "$output" = "ERROR: phase phase-001-triage is already in_progress" ]

    run read_state_value "state['current_phase_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "phase-001-triage" ]
}

@test "validate checks single in-progress phase and phase directory drift" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-execute --phase-type execute --skill-version v1 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]

    rm -rf "$TEST_DIR/.pipeline/phases/phase-001-execute/runtime/relay"

    run_update_pipeline --validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing expected directory"* ]]

    mkdir -p "$TEST_DIR/.pipeline/phases/phase-001-execute/runtime/relay"
    python3 - "$TEST_DIR/.pipeline/state.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)

state["phases"][0]["status"] = "in_progress"
state["current_phase_id"] = "phase-001-execute"
state["phases"].append(
    {
        "phase_id": "phase-002-align",
        "phase_type": "align",
        "skill_version": "v2",
        "status": "in_progress",
        "lock_state": "unlocked",
    }
)

with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY

    run_update_pipeline --validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"exactly one phase may be in_progress"* ]]
}

@test "validate rejects completed pipelines with pending or in-progress phases" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    python3 - "$TEST_DIR/.pipeline/state.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)

state["status"] = "complete"

with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY

    run_update_pipeline --validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"completed pipelines must not leave phases pending or in_progress"* ]]

    python3 - "$TEST_DIR/.pipeline/state.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)

state["phases"][0]["status"] = "in_progress"
state["current_phase_id"] = "phase-001-triage"

with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY

    run_update_pipeline --validate
    [ "$status" -eq 1 ]
    [[ "$output" == *"completed pipelines must not leave phases pending or in_progress"* ]]
    [[ "$output" == *"phase-001-triage (in_progress)"* ]]
}

@test "phase_started blocks execute phases until the predecessor gate passes" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship a deterministic execute handoff packet.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-000-triage --phase-type triage --skill-version v0
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 1 ]
    [[ "$output" == *"predecessor gate must pass before execute phase-002-execute can start"* ]]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-000-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-000-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run read_state_value "state['current_phase_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "phase-002-execute" ]
}

@test "gate events require align phases" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Keep execution gates aligned to the right phase type.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-triage/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-triage --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"gate events require align phases"* ]]
}

@test "phase_started requires an align predecessor for execute phases" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local packet_rel=".pipeline/phases/phase-001-triage/artifacts/execution-packet.json"
    local packet_abs="$TEST_DIR/$packet_rel"
    cat <<'EOF' > "$packet_abs"
{
  "mission": {
    "path": ".pipeline/mission/mission-v001.md",
    "hash": "sha256:mission"
  },
  "constraints": {
    "path": ".pipeline/phases/phase-001-triage/artifacts/constraints.json",
    "hash": "sha256:constraints"
  }
}
EOF

    python3 - "$TEST_DIR/.pipeline/state.json" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path) as fh:
    state = json.load(fh)

state["phases"][0]["status"] = "completed"
state["phases"][0]["lock_state"] = "locked"
state["phases"][0]["gate_result"] = {
    "status": "passed",
    "summary": "Execution readiness confirmed",
    "checked_at": "2100-01-01T00:00:00Z",
}

with open(path, "w") as fh:
    json.dump(state, fh, indent=2)
    fh.write("\n")
PY

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 1 ]
    [[ "$output" == *"predecessor must be an align phase before execute phase-002-execute can start"* ]]
}

@test "child_checkpoint stores a compact top-level projection and bounded phase details" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship child workflow checkpoints.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-002-execute" "reviewing" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run read_state_value "state['child_workflow'] == {'status': 'reviewing', 'last_checkpoint_at': '2100-01-01T00:00:00Z', 'phase_id': 'phase-002-execute', 'counts': {'total_slices': 4}}"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "'current_operation' in state['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "state['phases'][1]['child_workflow']['current_operation']"
    [ "$status" -eq 0 ]
    [ "$output" = "Reviewing slice-002" ]

    run read_state_value "'counts' in state['phases'][1]['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "state['phases'][1]['child_workflow'] != state['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_events_value "events[-1]['reconciled_forward']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
}

@test "child_checkpoint keeps state.json under 2KB during an active execute phase" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship compact child workflow checkpoints.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-align --phase-type align --skill-version v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-003-execute --phase-type execute --skill-version v3 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-002-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-002-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-002-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-002-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-003-execute
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-003-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-003-execute" "reviewing" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-003-execute
    [ "$status" -eq 0 ]

    local state_size
    state_size="$(wc -c < "$TEST_DIR/.pipeline/state.json")"
    [ "$state_size" -lt 2048 ]
}

@test "child_checkpoint truncates oversized adapter strings while preserving the full ledger event" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship bounded child workflow checkpoints.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adversarial_adapter_status_json "$status_abs" "phase-002-execute" "reviewing" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run read_state_value "state['phases'][1]['child_workflow']['progress_summary'].__len__()"
    [ "$status" -eq 0 ]
    [ "$output" = "120" ]

    run read_state_value "state['phases'][1]['child_workflow']['progress_summary'].endswith('...')"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "state['phases'][1]['child_workflow']['current_operation'].__len__()"
    [ "$status" -eq 0 ]
    [ "$output" = "80" ]

    run read_state_value "'current_child_phase' in state['phases'][1]['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "'current_slice_id' in state['phases'][1]['child_workflow']"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_state_value "state['phases'][1]['child_workflow']['verdict'].__len__()"
    [ "$status" -eq 0 ]
    [ "$output" = "40" ]

    run read_events_value "events[-1]['child_workflow']['progress_summary'].__len__()"
    [ "$status" -eq 0 ]
    [ "$output" = "2000" ]

    run read_events_value "events[-1]['child_workflow']['current_operation'].__len__()"
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    run read_events_value "events[-1]['child_workflow']['verdict'].__len__()"
    [ "$status" -eq 0 ]
    [ "$output" = "200" ]

    local state_size
    state_size="$(wc -c < "$TEST_DIR/.pipeline/state.json")"
    [ "$state_size" -lt 2048 ]
}

@test "child_checkpoint rejects phases that are not in_progress" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Reject invalid child checkpoints.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-002-execute" "reviewing" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 1 ]
    [[ "$output" == *"phase phase-002-execute must be in_progress before child_checkpoint"* ]]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    write_adapter_status_json "$status_abs" "phase-002-execute" "complete" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 1 ]
    [[ "$output" == *"phase phase-002-execute must be in_progress before child_checkpoint"* ]]
}

@test "child_checkpoint flags stale non-terminal child workflows after 30 minutes" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship stale child detection.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-002-execute" "reviewing" "2000-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run read_state_value "state['child_workflow']['stale']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
}

@test "phase_started blocks duplicate execute dispatch when an active child workflow lock exists" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship duplicate dispatch prevention.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-002-execute" "reviewing" "2100-01-01T00:00:00Z"

    local lock_rel=".pipeline/phases/phase-002-execute/runtime/adapter-lock.json"
    cat <<'EOF' > "$TEST_DIR/$lock_rel"
{"lock_id":"lock-001","phase_id":"phase-002-execute"}
EOF

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 1 ]
    [[ "$output" == *"existing child workflow is still active"* ]]
}

@test "artifact_recorded stores repo-relative manifest entries with sha256 hashes" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    local artifact_rel=".pipeline/phases/phase-001-align/artifacts/execution-spec.md"
    local artifact_abs="$TEST_DIR/$artifact_rel"
    cat <<'EOF' > "$artifact_abs"
# Execution Spec

Use a deterministic pipeline mutator.
EOF
    local artifact_hash
    artifact_hash="$(file_sha256 "$artifact_abs")"

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id execution-spec --artifact-path "$artifact_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run read_state_value "state['phases'][0]['artifact_manifest']['execution-spec']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$artifact_rel" ]

    run read_state_value "state['phases'][0]['artifact_manifest']['execution-spec']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$artifact_hash" ]

    run read_state_value "state['phases'][0]['artifact_manifest']['execution-spec']['role']"
    [ "$status" -eq 0 ]
    [ "$output" = "output" ]

    run read_events_value "events[-1]['artifact_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "execution-spec" ]

    run read_events_value "events[-1]['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$artifact_hash" ]
}

@test "phase_completed locks the phase and publishes a latest resume pointer" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    local artifact_rel=".pipeline/phases/phase-001-align/artifacts/decision-log.md"
    local artifact_abs="$TEST_DIR/$artifact_rel"
    cat <<'EOF' > "$artifact_abs"
# Decision Log

Picked the smallest proven change set.
EOF

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path "$artifact_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    local resume_rel=".pipeline/phases/phase-001-align/artifacts/resume.md"
    local resume_abs="$TEST_DIR/$resume_rel"

    [ -f "$resume_abs" ]

    run read_state_value "state['phases'][0]['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "completed" ]

    run read_state_value "state['phases'][0]['lock_state']"
    [ "$status" -eq 0 ]
    [ "$output" = "locked" ]

    run read_state_value "state['current_phase_id'] is None"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "state['latest_resume']"
    [ "$status" -eq 0 ]
    [ "$output" = "$resume_rel" ]

    run grep -F "phase-001-align" "$resume_abs"
    [ "$status" -eq 0 ]

    run grep -F "decision-log" "$resume_abs"
    [ "$status" -eq 0 ]

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "phase_completed rejects execute phases until the latest child workflow status is terminal" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Close execute only after the child workflow reaches a terminal checkpoint.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execute is ready to dispatch"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-002-execute
    [ "$status" -eq 1 ]
    [ "$output" = "ERROR: phase_completed rejected for execute phase phase-002-execute; child workflow status is missing, not terminal" ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-002-execute" "complete" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run read_state_value "state['phases'][1]['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "completed" ]
}

@test "superseded increments the active epoch and points to the replacement phase" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-align --phase-type align --skill-version v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event superseded --phase-id phase-001-align --summary "Superseded by phase-002-align after new constraints emerged"
    [ "$status" -eq 0 ]

    run read_state_value "state['active_epoch_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "epoch-002" ]

    run read_state_value "state['current_phase_id'] is None"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "state['phases'][0]['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "superseded" ]

    run read_state_value "state['phases'][0]['lock_state']"
    [ "$status" -eq 0 ]
    [ "$output" = "locked" ]

    run read_state_value "state['phases'][0]['superseded_by']"
    [ "$status" -eq 0 ]
    [ "$output" = "phase-002-align" ]

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "artifact_recorded rejects superseded phases" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-align --phase-type align --skill-version v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event superseded --phase-id phase-001-align --summary "Superseded by phase-002-align after new constraints emerged"
    [ "$status" -eq 0 ]

    local artifact_rel=".pipeline/phases/phase-001-align/artifacts/decision-log.md"
    local artifact_abs="$TEST_DIR/$artifact_rel"
    cat <<'EOF' > "$artifact_abs"
# Decision Log

Attempted after supersession.
EOF

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path "$artifact_rel" --artifact-role output
    [ "$status" -eq 1 ]
    [[ "$output" == *"phase phase-001-align is superseded"* ]]
}

@test "artifact_drift_detected records locked artifact drift and blocks automatic resume" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    local artifact_rel=".pipeline/phases/phase-001-align/artifacts/decision-log.md"
    local artifact_abs="$TEST_DIR/$artifact_rel"
    cat <<'EOF' > "$artifact_abs"
# Decision Log

Original locked artifact.
EOF

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id decision-log --artifact-path "$artifact_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    cat <<'EOF' > "$artifact_abs"
# Decision Log

Mutated after lock.
EOF

    run_update_pipeline --event artifact_drift_detected --phase-id phase-001-align --summary "Locked artifact changed after completion"
    [ "$status" -eq 0 ]

    run read_state_value "state['automatic_resume']['blocked']"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_state_value "state['automatic_resume']['reason']"
    [ "$status" -eq 0 ]
    [ "$output" = "artifact_drift_detected" ]

    run read_state_value "state['phases'][0]['artifact_drift']['artifacts'][0]['artifact_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "decision-log" ]
}

@test "mission_activated stores the mission pointer as repo-relative path plus hash" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship artifact lifecycle support.
EOF
    local mission_hash
    mission_hash="$(file_sha256 "$mission_abs")"

    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run read_state_value "state['mission_version']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$mission_rel" ]

    run read_state_value "state['mission_version']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$mission_hash" ]

    run read_state_value "state['mission_version'] == {'path': '$mission_rel', 'hash': '$mission_hash'}"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_events_value "events[-1]['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$mission_rel" ]

    run read_events_value "events[-1]['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$mission_hash" ]
}

@test "constraint_set_activated promotes the constraint file and stores the promoted pointer" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    local source_rel=".pipeline/phases/phase-001-align/artifacts/constraints-v1.json"
    local source_abs="$TEST_DIR/$source_rel"
    cat <<'EOF' > "$source_abs"
{"goal":"Keep state compact","allowed_paths":["scripts/pipeline/update-pipeline.sh"]}
EOF

    run_update_pipeline --event constraint_set_activated --constraint-path "$source_rel"
    [ "$status" -eq 0 ]

    local promoted_rel=".pipeline/constraints/sets/constraints-v1.json"
    local promoted_abs="$TEST_DIR/$promoted_rel"
    local promoted_hash
    promoted_hash="$(file_sha256 "$promoted_abs")"

    [ -f "$promoted_abs" ]
    cmp -s "$source_abs" "$promoted_abs"

    run read_state_value "state['active_constraint_set']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$promoted_rel" ]

    run read_state_value "state['active_constraint_set']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$promoted_hash" ]

    run read_state_value "state['active_constraint_set'] == {'path': '$promoted_rel', 'hash': '$promoted_hash'}"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_events_value "events[-1]['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$promoted_rel" ]

    run read_events_value "events[-1]['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$promoted_hash" ]
}

@test "gate_passed rejects invalid execution readiness constraints" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship gate validation.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"

    cat <<'EOF' > "$constraints_abs"
{"allowed_paths":["scripts/*"],"interface_changes":["Add gate"],"verification_commands":["bats tests/dev-scripts/update-pipeline.bats"],"non_goals":["No unrelated work"],"open_questions":[]}
EOF
    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"allowed_paths entries must not contain \"*\""* ]]

    cat <<'EOF' > "$constraints_abs"
{"allowed_paths":["scripts/pipeline/update-pipeline.sh"],"verification_commands":["bats tests/dev-scripts/update-pipeline.bats"],"non_goals":["No unrelated work"],"open_questions":[]}
EOF
    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"constraints.json must include interface_changes"* ]]

    cat <<'EOF' > "$constraints_abs"
{"allowed_paths":["scripts/pipeline/update-pipeline.sh"],"interface_changes":["Add gate"],"verification_commands":[],"non_goals":["No unrelated work"],"open_questions":[]}
EOF
    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"verification_commands must be a non-empty array"* ]]

    cat <<'EOF' > "$constraints_abs"
{"allowed_paths":["scripts/pipeline/update-pipeline.sh"],"interface_changes":["Add gate"],"verification_commands":["bats tests/dev-scripts/update-pipeline.bats"],"non_goals":[],"open_questions":[]}
EOF
    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"non_goals must be a non-empty array"* ]]

    cat <<'EOF' > "$constraints_abs"
{"allowed_paths":["scripts/pipeline/update-pipeline.sh"],"interface_changes":["Add gate"],"verification_commands":["bats tests/dev-scripts/update-pipeline.bats"],"non_goals":["No unrelated work"],"open_questions":["Still deciding"]}
EOF
    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"open_questions must be [] before gate_passed"* ]]

    run read_events_value "events[-1]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "constraint_set_activated" ]
}

@test "gate_passed rejects align phases missing a recorded execution-spec artifact" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship a complete execution packet.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    local spec_rel=".pipeline/phases/phase-001-align/artifacts/execution-spec.md"
    local spec_abs="$TEST_DIR/$spec_rel"
    cat <<'EOF' > "$spec_abs"
# Execution Spec

This file exists on disk but was never recorded into the phase manifest.
EOF

    local plan_rel=".pipeline/phases/phase-001-align/artifacts/verification-plan.md"
    local plan_abs="$TEST_DIR/$plan_rel"
    cat <<'EOF' > "$plan_abs"
# Verification Plan

- bats tests/dev-scripts/update-pipeline.bats
EOF

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id verification-plan --artifact-path "$plan_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [[ "$output" == *"execution-spec artifact must be recorded before gate_passed"* ]]
}

@test "gate_passed succeeds without a recorded decision-log artifact" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship the minimum execution contract without a decision log.
EOF

    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    local spec_rel=".pipeline/phases/phase-001-align/artifacts/execution-spec.md"
    local spec_abs="$TEST_DIR/$spec_rel"
    cat <<'EOF' > "$spec_abs"
# Execution Spec

Ship only the contract artifacts execute consumes.
EOF

    local plan_rel=".pipeline/phases/phase-001-align/artifacts/verification-plan.md"
    local plan_abs="$TEST_DIR/$plan_rel"
    cat <<'EOF' > "$plan_abs"
# Verification Plan

- bats tests/dev-scripts/update-pipeline.bats
EOF

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id execution-spec --artifact-path "$spec_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id verification-plan --artifact-path "$plan_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    local packet_rel=".pipeline/phases/phase-001-align/artifacts/execution-packet.json"
    local packet_abs="$TEST_DIR/$packet_rel"

    [ -f "$packet_abs" ]

    run read_state_value "'decision-log' in state['phases'][0].get('artifact_manifest', {})"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_json_file_value "$packet_abs" "'decision_log' in payload"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "gate_passed records summaries and builds execution-packet pointers" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship a packet the execute adapter can trust.
EOF
    local mission_hash
    mission_hash="$(file_sha256 "$mission_abs")"

    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    local spec_rel=".pipeline/phases/phase-001-align/artifacts/execution-spec.md"
    local spec_abs="$TEST_DIR/$spec_rel"
    cat <<'EOF' > "$spec_abs"
# Execution Spec

Make the gate authoritative.
EOF
    local spec_hash
    spec_hash="$(file_sha256 "$spec_abs")"

    local plan_rel=".pipeline/phases/phase-001-align/artifacts/verification-plan.md"
    local plan_abs="$TEST_DIR/$plan_rel"
    cat <<'EOF' > "$plan_abs"
# Verification Plan

- bash -n scripts/pipeline/update-pipeline.sh
- bats tests/dev-scripts/update-pipeline.bats
EOF
    local plan_hash
    plan_hash="$(file_sha256 "$plan_abs")"

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id execution-spec --artifact-path "$spec_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event artifact_recorded --phase-id phase-001-align --artifact-id verification-plan --artifact-path "$plan_rel" --artifact-role output
    [ "$status" -eq 0 ]

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    local promoted_rel=".pipeline/constraints/sets/constraints.json"
    local promoted_abs="$TEST_DIR/$promoted_rel"
    local promoted_hash
    promoted_hash="$(file_sha256 "$promoted_abs")"

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    local packet_rel=".pipeline/phases/phase-001-align/artifacts/execution-packet.json"
    local packet_abs="$TEST_DIR/$packet_rel"

    [ -f "$packet_abs" ]

    run read_state_value "state['phases'][0]['gate_result']['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "passed" ]

    run read_state_value "state['phases'][0]['gate_result']['summary']"
    [ "$status" -eq 0 ]
    [ "$output" = "Execution readiness confirmed" ]

    run read_state_value "state['phases'][0]['gate_result']['evidence_paths']"
    [ "$status" -eq 0 ]
    [ "$output" = $'.pipeline/phases/phase-001-align/artifacts/constraints.json\n.pipeline/phases/phase-001-align/artifacts/execution-spec.md\n.pipeline/phases/phase-001-align/artifacts/verification-plan.md' ]

    run read_events_value "events[-1]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "gate_passed" ]

    run read_events_value "events[-1]['summary']"
    [ "$status" -eq 0 ]
    [ "$output" = "Execution readiness confirmed" ]

    run read_json_file_value "$packet_abs" "payload.get('constraints') is not None and payload.get('execution_spec') is not None and payload.get('mission') is not None and payload.get('verification_plan') is not None"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]

    run read_json_file_value "$packet_abs" "payload['mission']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$mission_rel" ]

    run read_json_file_value "$packet_abs" "payload['mission']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$mission_hash" ]

    run read_json_file_value "$packet_abs" "payload['constraints']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$promoted_rel" ]

    run read_json_file_value "$packet_abs" "payload['constraints']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$promoted_hash" ]

    run read_json_file_value "$packet_abs" "payload['execution_spec']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$spec_rel" ]

    run read_json_file_value "$packet_abs" "payload['execution_spec']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$spec_hash" ]

    run read_json_file_value "$packet_abs" "payload['verification_plan']['path']"
    [ "$status" -eq 0 ]
    [ "$output" = "$plan_rel" ]

    run read_json_file_value "$packet_abs" "payload['verification_plan']['hash']"
    [ "$status" -eq 0 ]
    [ "$output" = "$plan_hash" ]

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]
}

@test "gate events are terminal per phase after gate_failed" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Recover by adding a new align phase instead of mutating the old one.
EOF

    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_failed --phase-id phase-001-align --summary "Questions remain"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 1 ]
    [ "$output" = "ERROR: gate outcome already set for phase phase-001-align; gate events are terminal per phase" ]

    local packet_rel=".pipeline/phases/phase-001-align/artifacts/execution-packet.json"
    [ ! -f "$TEST_DIR/$packet_rel" ]

    run read_state_value "state['phases'][0]['gate_result']['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "failed" ]

    run read_state_value "state['phases'][0]['gate_result']['summary']"
    [ "$status" -eq 0 ]
    [ "$output" = "Questions remain" ]

    run read_events_value "events[-1]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "gate_failed" ]
}

@test "pipeline_completed marks the pipeline complete and appends retrospective metrics" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local phase_one="a1"
    local phase_two="a2"
    local phase_three="a3"
    local execute_phase="x4"
    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship pipeline completion bookkeeping.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$phase_one" --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$phase_two" --phase-type align --skill-version v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$phase_three" --phase-type align --skill-version v3
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id "$execute_phase" --phase-type execute --skill-version v4 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$phase_one"
    [ "$status" -eq 0 ]

    run_update_pipeline --event superseded --phase-id "$phase_one" --summary "Replaced"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$phase_two"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id "$phase_two"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_failed --phase-id "$phase_two" --summary "Blocked"
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/$phase_three/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "$phase_three"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$phase_three"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id "$phase_three"
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id "$phase_three" --summary "Ready."
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id "$execute_phase"
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/$execute_phase/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "$execute_phase" "complete" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id "$execute_phase"
    [ "$status" -eq 0 ]

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

    run read_state_value "'retrospective' in state"
    [ "$status" -eq 0 ]
    [ "$output" = "False" ]

    run read_events_value "events[-2]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "pipeline_completed" ]

    run read_events_value "events[-1]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "pipeline_retrospective" ]

    run read_events_value "events[-1]['pipeline_id']"
    [ "$status" -eq 0 ]
    [ "$output" = "mission-001" ]

    run read_events_value "events[-1]['metrics']['total_phases']"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]

    run read_events_value "events[-1]['metrics']['epoch_resets']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_events_value "events[-1]['metrics']['gate_failures']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_events_value "events[-1]['metrics']['rework_phases']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_events_value "events[-1]['metrics']['execute_slice_counts']['$execute_phase']"
    [ "$status" -eq 0 ]
    [ "$output" = "4" ]

    run env TEST_DIR="$TEST_DIR" python3 -c "import os; print(os.path.getsize(os.path.join(os.environ['TEST_DIR'], '.pipeline', 'state.json')) < 2048)"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
}

@test "pipeline_completed rejects phases that are still pending" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event pipeline_completed
    [ "$status" -eq 1 ]
    [[ "$output" == *"phases still pending"* ]]
    [[ "$output" == *"phase-001-triage (pending)"* ]]
}

@test "phase_added is rejected after pipeline_completed" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-triage --phase-type triage --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-triage
    [ "$status" -eq 0 ]

    run_update_pipeline --event pipeline_completed
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-align --phase-type align --skill-version v2
    [ "$status" -eq 1 ]
    [ "$output" = "ERROR: pipeline is complete; phase_added rejected" ]
}

@test "--rebuild recreates state.json from events.ndjson without reading the current snapshot" {
    run_update_pipeline --event init_pipeline --mission-id mission-001
    [ "$status" -eq 0 ]

    local mission_rel=".pipeline/mission/mission-v001.md"
    local mission_abs="$TEST_DIR/$mission_rel"
    cat <<'EOF' > "$mission_abs"
# Mission

Ship deterministic state replay.
EOF
    run_update_pipeline --event mission_activated --mission-path "$mission_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-001-align --phase-type align --skill-version v1
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_added --phase-id phase-002-execute --phase-type execute --skill-version v2 --adapter-id manage-codex-relay --adapter-version adapter-v2
    [ "$status" -eq 0 ]

    local constraints_rel=".pipeline/phases/phase-001-align/artifacts/constraints.json"
    local constraints_abs="$TEST_DIR/$constraints_rel"
    write_valid_constraints_json "$constraints_abs"
    record_align_gate_artifacts "phase-001-align"

    run_update_pipeline --event constraint_set_activated --constraint-path "$constraints_rel"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-001-align
    [ "$status" -eq 0 ]

    run_update_pipeline --event gate_passed --phase-id phase-001-align --summary "Execution readiness confirmed"
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_started --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    local status_rel=".pipeline/phases/phase-002-execute/runtime/adapter-status.json"
    local status_abs="$TEST_DIR/$status_rel"
    write_adapter_status_json "$status_abs" "phase-002-execute" "complete" "2100-01-01T00:00:00Z"

    run_update_pipeline --event child_checkpoint --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run_update_pipeline --event phase_completed --phase-id phase-002-execute
    [ "$status" -eq 0 ]

    run_update_pipeline --event pipeline_completed
    [ "$status" -eq 0 ]

    local baseline_state="$TEST_DIR/original-state.json"
    cp "$TEST_DIR/.pipeline/state.json" "$baseline_state"

    printf 'not valid json\n' > "$TEST_DIR/.pipeline/state.json"

    run_update_pipeline --rebuild
    [ "$status" -eq 0 ]

    cmp -s "$baseline_state" "$TEST_DIR/.pipeline/state.json"

    run_update_pipeline --validate
    [ "$status" -eq 0 ]
    [ "$output" = "state.json: consistent" ]

    run env TEST_DIR="$TEST_DIR" python3 -c "import os; print(os.path.getsize(os.path.join(os.environ['TEST_DIR'], '.pipeline', 'state.json')) < 2048)"
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
}

#!/usr/bin/env bats

setup() {
    TEST_DIR="$(mktemp -d)"
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"

    mkdir -p "$TEST_DIR/scripts/relay" "$TEST_DIR/.relay"
    cp "$PROJECT_ROOT/scripts/relay/update-batch.sh" "$TEST_DIR/scripts/relay/"
    chmod +x "$TEST_DIR/scripts/relay/update-batch.sh"
}

teardown() {
    rm -rf "$TEST_DIR"
}

relay_file_path() {
    local root="${1:-$TEST_DIR/.relay}"
    local name="$2"
    printf '%s/%s\n' "${root%/}" "$name"
}

write_batch_fixture() {
    local root="${1:-$TEST_DIR/.relay}"
    mkdir -p "$root"
    cat > "$(relay_file_path "$root" "batch.json")"
}

write_plan_fixture() {
    local root="${1:-$TEST_DIR/.relay}"
    mkdir -p "$root"
    cat > "$(relay_file_path "$root" "plan.json")"
}

copy_batch_to_plan() {
    local root="${1:-$TEST_DIR/.relay}"
    cp "$(relay_file_path "$root" "batch.json")" "$(relay_file_path "$root" "plan.json")"
}

read_batch_value() {
    local expr="$1"
    local root="${2:-$TEST_DIR/.relay}"
    python3 - "$(relay_file_path "$root" "batch.json")" "$expr" <<'PY'
import json
import sys

batch_path, expr = sys.argv[1], sys.argv[2]
with open(batch_path) as fh:
    batch = json.load(fh)

value = eval(expr, {"__builtins__": {}}, {"batch": batch})
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
    local root="${2:-$TEST_DIR/.relay}"
    python3 - "$(relay_file_path "$root" "events.ndjson")" "$expr" <<'PY'
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

run_update_batch() {
    run env TEST_DIR="$TEST_DIR" /bin/bash -lc 'cd "$TEST_DIR" && ./scripts/relay/update-batch.sh "$@"' bash "$@"
}

@test "--root writes relay state under the supplied directory" {
    local relay_root_rel="custom-relay"
    local relay_root="$TEST_DIR/$relay_root_rel"

    write_batch_fixture "$relay_root" <<'EOF'
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

    printf 'handoff body\n' > "$TEST_DIR/handoff.md"

    run_update_batch \
        --root "$relay_root_rel" \
        --slice slice-001 \
        --event attempt_started \
        --summary "Dispatching implementation worker" \
        --handoff "$TEST_DIR/handoff.md"
    [ "$status" -eq 0 ]

    [ -f "$relay_root/batch.json" ]
    [ -f "$relay_root/events.ndjson" ]
    [ -d "$relay_root/archive" ]
    [ -f "$relay_root/archive/fixture-batch-slice-001-attempt_started-1.md" ]
    [ ! -f "$TEST_DIR/.relay/events.ndjson" ]
    [ ! -d "$TEST_DIR/.relay/archive" ]

    run read_batch_value "batch['current_slice']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "slice-001" ]

    run read_events_value "events[0]['summary']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "Dispatching implementation worker" ]
}

@test "--root rebuild uses the rooted relay ledger" {
    local relay_root_rel="rooted-relay"
    local relay_root="$TEST_DIR/$relay_root_rel"

    write_plan_fixture "$relay_root" <<'EOF'
{
  "batch_id": "rooted-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "rooted implementation",
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

    cat > "$relay_root/events.ndjson" <<'EOF'
{"ts":"2026-03-18T12:00:00Z","event":"attempt_started","mutation":"attempt_started","slice":"slice-001","summary":"Dispatch"}
{"ts":"2026-03-18T12:05:00Z","event":"review_recorded","mutation":"review_clean","slice":"slice-001","summary":"CLEAN"}
EOF

    write_plan_fixture <<'EOF'
{
  "batch_id": "default-batch",
  "slices": [
    {
      "id": "slice-999",
      "type": "implement",
      "task": "default implementation",
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
  "current_slice": "slice-999",
  "convergence_attempts": 0
}
EOF

    cat > "$TEST_DIR/.relay/events.ndjson" <<'EOF'
{"ts":"2026-03-18T12:00:00Z","event":"orchestrator_direct","mutation":"orchestrator_direct","slice":"slice-999","summary":"default"}
EOF

    run_update_batch --root "$relay_root_rel" --rebuild
    [ "$status" -eq 0 ]

    run read_batch_value "batch['batch_id']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "rooted-batch" ]

    run read_batch_value "batch['slices'][0]['id']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "slice-001" ]

    run read_batch_value "batch['slices'][0]['impl_attempts']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_batch_value "batch['slices'][0]['review']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "CLEAN" ]

    [ ! -f "$TEST_DIR/.relay/batch.json" ]
}

@test "--root with --batch overrides only batch.json path" {
    local relay_root_rel="custom-root"
    local relay_root="$TEST_DIR/$relay_root_rel"
    local batch_override="$TEST_DIR/override/batch.json"

    mkdir -p "$TEST_DIR/override"

    write_batch_fixture "$relay_root" <<'EOF'
{
  "batch_id": "rooted-batch",
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
    # Copy batch to the override location
    cp "$relay_root/batch.json" "$batch_override"

    run_update_batch \
        --root "$relay_root_rel" \
        --batch "$batch_override" \
        --slice slice-001 \
        --event impl_dispatched \
        --summary "Override test"
    [ "$status" -eq 0 ]

    # batch.json should be at the override location, NOT under relay root
    [ -f "$batch_override" ]

    # events.ndjson and archive should be under relay root, NOT at override location
    [ -f "$relay_root/events.ndjson" ]
    [ ! -f "$TEST_DIR/override/events.ndjson" ]

    # Verify the override batch was actually updated
    run python3 -c "import json; b=json.load(open('$batch_override')); print(b['slices'][0]['verification'])"
    [ "$status" -eq 0 ]
    [ "$output" = "Override test" ]

    # Verify events landed under relay root
    run read_events_value "events[0]['summary']" "$relay_root"
    [ "$status" -eq 0 ]
    [ "$output" = "Override test" ]
}

@test "add_slice rejects invalid slice types" {
    write_batch_fixture <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "implement",
      "task": "existing",
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

    run_update_batch --event add_slice --task "bad slice" --type invalid-type --scope "scripts/relay"
    [ "$status" -eq 1 ]
    [[ "$output" == *"invalid slice type"* ]]
}

@test "add_slice records domain skills, verification commands, and success criteria" {
    write_batch_fixture <<'EOF'
{
  "batch_id": "fixture-batch",
  "slices": [
    {
      "id": "slice-001",
      "type": "review",
      "task": "review existing work",
      "file_scope": ["scripts/relay"],
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
    copy_batch_to_plan

    run_update_batch \
        --event add_slice \
        --task "implement relay fixes" \
        --type implement \
        --scope "scripts/relay,tests/dev-scripts" \
        --skills "manage-codex,tdd" \
        --verification "bash -n scripts/relay/update-batch.sh" \
        --verification "./scripts/relay/update-batch.sh --validate" \
        --criteria "All relay findings resolved"
    [ "$status" -eq 0 ]

    run read_batch_value "batch['slices'][-1]['id']"
    [ "$status" -eq 0 ]
    [ "$output" = "slice-002" ]

    run read_batch_value "batch['slices'][-1]['domain_skills']"
    [ "$status" -eq 0 ]
    [ "$output" = $'manage-codex\ntdd' ]

    run read_batch_value "batch['slices'][-1]['verification_commands']"
    [ "$status" -eq 0 ]
    [ "$output" = $'bash -n scripts/relay/update-batch.sh\n./scripts/relay/update-batch.sh --validate' ]

    run read_batch_value "batch['slices'][-1]['success_criteria']"
    [ "$status" -eq 0 ]
    [ "$output" = "All relay findings resolved" ]

    run read_events_value "events[0]['event']"
    [ "$status" -eq 0 ]
    [ "$output" = "slice_added" ]

    run read_events_value "events[0]['slice']"
    [ "$status" -eq 0 ]
    [ "$output" = "slice-002" ]

    run read_events_value "events[0]['domain_skills']"
    [ "$status" -eq 0 ]
    [ "$output" = $'manage-codex\ntdd' ]

    cat > "$TEST_DIR/.relay/batch.json" <<'EOF'
{
  "phase": "corrupt",
  "slices": []
}
EOF

    run_update_batch --rebuild
    [ "$status" -eq 0 ]

    run read_batch_value "batch['slices'][-1]['id']"
    [ "$status" -eq 0 ]
    [ "$output" = "slice-002" ]

    run read_batch_value "batch['slices'][-1]['success_criteria']"
    [ "$status" -eq 0 ]
    [ "$output" = "All relay findings resolved" ]
}

@test "review_clean enters converge phase when only converge slices remain pending" {
    write_batch_fixture <<'EOF'
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
      "impl_attempts": 1,
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
  "phase": "implement",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF

    run_update_batch --slice slice-001 --event review_clean --summary CLEAN
    [ "$status" -eq 0 ]

    run read_batch_value "batch['phase']"
    [ "$status" -eq 0 ]
    [ "$output" = "converge" ]

    run read_batch_value "batch['current_slice']"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run read_batch_value "batch['slices'][1]['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "pending" ]
}

@test "attempt_started rejects done slices" {
    write_batch_fixture <<'EOF'
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

    run_update_batch --slice slice-001 --event attempt_started
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: attempt_started rejected; slice slice-001 is already done"* ]]
    [ ! -e "$TEST_DIR/.relay/events.ndjson" ]
}

@test "converge_complete rejects unfinished non-converge slices" {
    write_batch_fixture <<'EOF'
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

    run_update_batch --event converge_complete --summary Hardened
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: converge_complete rejected; slice slice-001 is still pending"* ]]
    [ ! -e "$TEST_DIR/.relay/events.ndjson" ]
}

@test "attempt lifecycle and convergence rebuild from ledger evidence" {
    write_batch_fixture <<'EOF'
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
  "phase": "implement",
  "current_slice": "slice-001",
  "convergence_attempts": 0
}
EOF
    copy_batch_to_plan

    run_update_batch --slice slice-001 --event attempt_started --summary "Dispatching implementation worker"
    [ "$status" -eq 0 ]

    run_update_batch --slice slice-001 --event impl_dispatched --summary "Implementation handoff read"
    [ "$status" -eq 0 ]

    run_update_batch --slice slice-001 --event review_clean --summary CLEAN
    [ "$status" -eq 0 ]

    run_update_batch --event converge_complete --summary Hardened
    [ "$status" -eq 0 ]

    run env TEST_DIR="$TEST_DIR" python3 -c "import json, os; [json.loads(line) for line in open(os.path.join(os.environ['TEST_DIR'], '.relay', 'events.ndjson')) if line.strip()]"
    [ "$status" -eq 0 ]

    run read_events_value "[event['event'] for event in events]"
    [ "$status" -eq 0 ]
    [ "$output" = $'attempt_started\nattempt_finished\nreview_recorded\nconverge_started' ]

    cat > "$TEST_DIR/.relay/batch.json" <<'EOF'
{
  "phase": "corrupt",
  "current_slice": "nope",
  "slices": []
}
EOF

    run_update_batch --rebuild
    [ "$status" -eq 0 ]

    run read_batch_value "batch['phase']"
    [ "$status" -eq 0 ]
    [ "$output" = "complete" ]

    run read_batch_value "batch['current_slice']"
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    run read_batch_value "batch['slices'][0]['impl_attempts']"
    [ "$status" -eq 0 ]
    [ "$output" = "1" ]

    run read_batch_value "batch['slices'][0]['review']"
    [ "$status" -eq 0 ]
    [ "$output" = "CLEAN" ]

    run read_batch_value "batch['slices'][1]['status']"
    [ "$status" -eq 0 ]
    [ "$output" = "done" ]
}

@test "completed batches reject add_slice mutations" {
    write_batch_fixture <<'EOF'
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
      "status": "done",
      "impl_attempts": 1,
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

    run_update_batch --event converge_complete --summary Hardened
    [ "$status" -eq 0 ]

    run_update_batch --event add_slice --task "late work" --type implement --scope "scripts/relay"
    [ "$status" -ne 0 ]
    [[ "$output" == *"ERROR: batch is complete; add_slice rejected"* ]]
}

@test "validate rejects completed batches with pending slices" {
    write_batch_fixture <<'EOF'
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
      "impl_attempts": 1,
      "review_rejections": 0
    }
  ],
  "phase": "complete",
  "current_slice": "",
  "convergence_attempts": 0
}
EOF

    run_update_batch --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRIFT: completed batches must not leave slices pending or in_progress"* ]]
    [[ "$output" == *"slice-001 (pending)"* ]]
}

@test "validate rejects invalid batch phases" {
    write_batch_fixture <<'EOF'
{
  "batch_id": "fixture-batch",
  "phase": "corrupt",
  "current_slice": "",
  "convergence_attempts": 0,
  "slices": []
}
EOF

    run_update_batch --validate
    [ "$status" -ne 0 ]
    [[ "$output" == *"DRIFT: batch phase 'corrupt' is invalid"* ]]
}

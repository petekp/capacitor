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

write_batch_fixture() {
    cat > "$TEST_DIR/.relay/batch.json"
}

write_plan_fixture() {
    cat > "$TEST_DIR/.relay/plan.json"
}

copy_batch_to_plan() {
    cp "$TEST_DIR/.relay/batch.json" "$TEST_DIR/.relay/plan.json"
}

read_batch_value() {
    local expr="$1"
    python3 - "$TEST_DIR/.relay/batch.json" "$expr" <<'PY'
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
    python3 - "$TEST_DIR/.relay/events.ndjson" "$expr" <<'PY'
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
  "phase": "plan",
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
  "phase": "review",
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
  "phase": "review",
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
  "phase": "plan",
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

setup_test_workspace() {
    TEST_DIR="$(mktemp -d)"
    TEST_HOME=""
    PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

    if [[ "${1:-}" == "with_home" ]]; then
        TEST_HOME="$TEST_DIR/home"
        mkdir -p "$TEST_HOME"
    fi
}

teardown_test_workspace() {
    rm -rf "$TEST_DIR"
}

copy_project_scripts() {
    local dest_root="$1"
    shift

    local rel_path
    for rel_path in "$@"; do
        mkdir -p "$dest_root/$(dirname "$rel_path")"
        cp "$PROJECT_ROOT/$rel_path" "$dest_root/$rel_path"
        chmod +x "$dest_root/$rel_path"
    done
}

init_git_repo() {
    local repo="$1"

    git -C "$repo" init -q
}

write_fixture() {
    local path="$1"

    mkdir -p "$(dirname "$path")"
    cat > "$path"
}

assert_json_files_equal() {
    local expected_path="$1"
    local actual_path="$2"

    run python3 - "$expected_path" "$actual_path" <<'PY'
import json
import sys

expected_path, actual_path = sys.argv[1], sys.argv[2]
with open(expected_path) as expected_fh:
    expected = json.load(expected_fh)
with open(actual_path) as actual_fh:
    actual = json.load(actual_fh)

print(expected == actual)
PY
    [ "$status" -eq 0 ]
    [ "$output" = "True" ]
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
        stripped = line.strip()
        if stripped:
            events.append(json.loads(stripped))

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

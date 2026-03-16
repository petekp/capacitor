#!/usr/bin/env bats

setup() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VERIFY="$PROJECT_ROOT/scripts/verify/verify.sh"
  if [[ ! -x "$PROJECT_ROOT/.verifier/.venv/bin/python" ]]; then
    skip "verifier dependencies not bootstrapped"
  fi
}

copy_fixture_repo() {
  local fixture_name="$1"
  local temp_root
  temp_root="$(mktemp -d)"
  mkdir -p "$temp_root/repo"
  cp -R "$PROJECT_ROOT/tests/verify/fixtures/$fixture_name"/. "$temp_root/repo/"
  printf '%s\n' "$temp_root/repo"
}

@test "bootstrap is idempotent and scaffolds verifier files" {
  temp_root="$(mktemp -d)"
  mkdir -p "$temp_root/repo"

  run env \
    VENV_DIR="$temp_root/venv" \
    VERIFY_SKIP_PYTHON_DEPS=1 \
    VERIFY_SKIP_APALACHE_INSTALL=1 \
    "$VERIFY" --repo-root "$temp_root/repo" --bootstrap
  [ "$status" -eq 0 ]

  run env \
    VENV_DIR="$temp_root/venv" \
    VERIFY_SKIP_PYTHON_DEPS=1 \
    VERIFY_SKIP_APALACHE_INSTALL=1 \
    "$VERIFY" --repo-root "$temp_root/repo" --bootstrap
  [ "$status" -eq 0 ]

  [ -f "$temp_root/repo/.verifier/structural.yaml" ]
  [ -f "$temp_root/repo/.verifier/elegance.yaml" ]
  [ -d "$temp_root/repo/.verifier/specs" ]
}

@test "install-deps downloads Apalache from the configured release repo" {
  temp_root="$(mktemp -d)"
  fake_home="$temp_root/home"
  fake_bin="$temp_root/fake-bin"
  fake_venv="$temp_root/venv"
  mkdir -p "$fake_home" "$fake_bin" "$fake_venv/bin"

  cat > "$fake_venv/bin/pip" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fake_venv/bin/pip"

  cat > "$fake_bin/java" <<'SH'
#!/usr/bin/env bash
echo 'openjdk version "17.0.18"'
SH
  chmod +x "$fake_bin/java"

  cat > "$fake_bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
url=""
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done
printf '%s' "$url" > "$HOME/requested-url.txt"
touch "$out"
SH
  chmod +x "$fake_bin/curl"

  cat > "$fake_bin/tar" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
dest=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -C)
      dest="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
mkdir -p "$dest/apalache-${APALACHE_VERSION}/bin"
cat > "$dest/apalache-${APALACHE_VERSION}/bin/apalache-mc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$dest/apalache-${APALACHE_VERSION}/bin/apalache-mc"
SH
  chmod +x "$fake_bin/tar"

  run env \
    HOME="$fake_home" \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    PYTHON_BIN="$PROJECT_ROOT/.verifier/.venv/bin/python" \
    VENV_DIR="$fake_venv" \
    VERIFY_SKIP_PYTHON_DEPS=1 \
    APALACHE_VERSION="9.9.9" \
    APALACHE_REPO="example/apalache" \
    "$PROJECT_ROOT/scripts/verify/install-deps.sh"
  [ "$status" -eq 0 ]

  expected_url="https://github.com/example/apalache/releases/download/v9.9.9/apalache.tgz"
  actual_url="$(cat "$fake_home/requested-url.txt")"
  [ "$actual_url" = "$expected_url" ]
  [ -x "$fake_home/.local/bin/apalache-mc" ]
}

@test "layer1 allows raw tmux commands inside the declared owner" {
  fixture="$(copy_fixture_repo basic-repo)"
  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$fixture" --layers 1 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
}

@test "layer1 fails when raw tmux commands appear outside the declared owner" {
  fixture="$(copy_fixture_repo violations)"
  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$fixture" --layers 1 --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"violation_count":'* ]]

  run python3 - <<'PY' "$fixture/.verifier/reports/last-run.json"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] > 0
rules = {violation["rule"] for violation in payload["layer_results"]["1"]["violations"]}
assert "tmux_router_exclusive_command_owner" in rules
PY
  [ "$status" -eq 0 ]
}

@test "layer1 fails when a retired shadow module path returns" {
  fixture="$(copy_fixture_repo shadow-module)"
  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$fixture" --layers 1 --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'"violation_count":'* ]]

  run python3 - <<'PY' "$fixture/.verifier/reports/last-run.json"
import json
import pathlib
import sys
payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] > 0
rules = {violation["rule"] for violation in payload["layer_results"]["1"]["violations"]}
assert "shadow_runtime_activation_path_deleted" in rules
PY
  [ "$status" -eq 0 ]
}

@test "layer2 behavioral specs parse and execute when Apalache is installed" {
  if ! command -v apalache-mc >/dev/null 2>&1; then
    skip "apalache-mc is not installed"
  fi

  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$PROJECT_ROOT" --layers 2 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
}

@test "verifier-generated artifacts are ignored across nested repos and python caches stay untracked" {
  run git check-ignore --no-index -v \
    tests/verify/fixtures/basic-repo/.verifier/facts/current.json \
    tests/verify/fixtures/basic-repo/.verifier/reports/last-run.json \
    .verifier/specs/__pycache__/RuntimeBoundaryContracts.cpython-313.pyc
  [ "$status" -eq 0 ]
  [[ "$output" == *".verifier/facts/"* ]]
  [[ "$output" == *".verifier/reports/"* ]]
  [[ "$output" == *"__pycache__/"* ]]

  run bash -lc "git ls-files .verifier/specs/__pycache__"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "layer2 executes proof registry commands" {
  temp_root="$(mktemp -d)"
  mkdir -p "$temp_root/repo/.verifier/specs" "$temp_root/repo/scripts"

  cat > "$temp_root/repo/.verifier/specs/proof_registry.yaml" <<'YAML'
proofs:
  - name: smoke_proof
    layer: 2
    path: scripts/proof-ok.sh
    command:
      - ./scripts/proof-ok.sh
YAML

  cat > "$temp_root/repo/scripts/proof-ok.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
touch .proof-ran
SH
  chmod +x "$temp_root/repo/scripts/proof-ok.sh"

  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$temp_root/repo" --layers 2 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
  [ -f "$temp_root/repo/.proof-ran" ]
}

@test "layer2 reports proof registry failures as behavioral violations" {
  temp_root="$(mktemp -d)"
  mkdir -p "$temp_root/repo/.verifier/specs" "$temp_root/repo/scripts"

  cat > "$temp_root/repo/.verifier/specs/proof_registry.yaml" <<'YAML'
proofs:
  - name: failing_proof
    layer: 2
    path: scripts/proof-fail.sh
    command:
      - ./scripts/proof-fail.sh
    message: Focused proof failed
    diagnosis: The focused proof command should surface its failure through Layer 2.
YAML

  cat > "$temp_root/repo/scripts/proof-fail.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
echo "proof failure output" >&2
exit 7
SH
  chmod +x "$temp_root/repo/scripts/proof-fail.sh"

  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$temp_root/repo" --layers 2 --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'failing_proof'* ]]
  [[ "$output" == *'Focused proof failed'* ]]

  run python3 - <<'PY' "$temp_root/repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
violations = payload["layer_results"]["2"]["violations"]
assert any(v["rule"] == "failing_proof" for v in violations)
assert any("proof failure output" in v["diagnosis"] for v in violations)
PY
  [ "$status" -eq 0 ]
}

@test "evolve fails when a canonical doc claim is not covered by a verifier rule" {
  fixture="$(copy_fixture_repo wrappers)"
  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$fixture" --layers 1 --evolve --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'uncovered_doc_claim'* ]]
}

@test "legacy guard wrappers delegate to the formal verifier" {
  rust_swift_wrapper="$(cat "$PROJECT_ROOT/docs/plans/rust-swift-boundary-legibility/guard.sh")"
  ghostty_wrapper="$(cat "$PROJECT_ROOT/docs/plans/ghostty-applescript/guard.sh")"
  terminal_wrapper="$(cat "$PROJECT_ROOT/docs/plans/terminal-routing-foundation/guard.sh")"

  [[ "$rust_swift_wrapper" == *'scripts/verify/verify.sh'* ]]
  [[ "$rust_swift_wrapper" == *'--groups rust-swift-boundary-legibility'* ]]
  [[ "$ghostty_wrapper" == *'--groups ghostty-applescript'* ]]
  [[ "$terminal_wrapper" == *'--groups terminal-routing-foundation'* ]]
}

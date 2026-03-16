#!/usr/bin/env bats

setup_file() {
  PROJECT_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  VERIFY="$PROJECT_ROOT/scripts/verify/verify.sh"

  if [[ -n "${VENV_DIR:-}" ]]; then
    TEST_VENV_DIR="$VENV_DIR"
    TEST_VENV_ROOT=""
  else
    TEST_VENV_ROOT="$(mktemp -d)"
    TEST_VENV_DIR="$TEST_VENV_ROOT/verifier-venv"
  fi

  export PROJECT_ROOT
  export VERIFY
  export TEST_VENV_DIR

  if [[ ! -x "$TEST_VENV_DIR/bin/python" ]]; then
    env VENV_DIR="$TEST_VENV_DIR" "$PROJECT_ROOT/scripts/verify/install-deps.sh" >/dev/null
  fi
}

teardown_file() {
  if [[ -n "${TEST_VENV_ROOT:-}" && -d "${TEST_VENV_ROOT:-}" ]]; then
    rm -rf "$TEST_VENV_ROOT"
  fi
}

setup() {
  export PROJECT_ROOT
  export VERIFY
  export TEST_VENV_DIR
}

run_verify() {
  run env VENV_DIR="$TEST_VENV_DIR" "$VERIFY" "$@"
}

new_temp_repo() {
  mktemp -d
}

init_git_repo() {
  local repo="$1"
  git -C "$repo" init -q
  git -C "$repo" config user.email "verify-tests@example.com"
  git -C "$repo" config user.name "Verifier Tests"
}

commit_repo() {
  local repo="$1"
  git -C "$repo" add .
  git -C "$repo" commit -qm "fixture"
}

write_doc_governance_fixture() {
  local repo="$1"
  mkdir -p \
    "$repo/.verifier" \
    "$repo/.claude/docs" \
    "$repo/docs/architecture-decisions" \
    "$repo/docs/archive/architecture-history" \
    "$repo/docs/audits/sample" \
    "$repo/docs/manual-qa" \
    "$repo/docs/plans/sample"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs:
    - .claude/docs/architecture-primer.md
    - docs/ARCHITECTURE.md
    - docs/architecture-decisions/004-dedicated-local-runtime-service.md
  doc_governance:
    primer: .claude/docs/architecture-primer.md
    spec: docs/ARCHITECTURE.md
    rationale: docs/architecture-decisions/004-dedicated-local-runtime-service.md
    recent_deltas: AGENT_CHANGELOG.md
    generated_aid: .verifier/reports/architecture-packet.md
    support_docs:
      - CLAUDE.md
      - .claude/docs/README.md
      - .claude/docs/debugging-guide.md
      - .claude/docs/gotchas.md
      - .claude/docs/release-guide.md
    historical_globs:
      - docs/audits/**/*.md
      - docs/manual-qa/**/*.md
      - docs/plans/**/*.md
    archived_globs:
      - docs/archive/architecture-history/**/*.md
ownership: []
boundaries: []
patterns: []
migration: []
YAML

  cat > "$repo/.claude/docs/architecture-primer.md" <<'MD'
# Architecture Primer

> Doc role: `agent-entrypoint`
> Status: Current. Read this first for architecture orientation.

## Read Order

1. `.claude/docs/architecture-primer.md`
2. `docs/ARCHITECTURE.md`
3. `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

## Ignore As Current Architecture

- `AGENT_CHANGELOG.md`
- `docs/audits/`
- `docs/plans/`
- `docs/manual-qa/`
MD

  cat > "$repo/docs/ARCHITECTURE.md" <<'MD'
# Architecture

> Doc role: `canonical-spec`
> Status: Current architecture spec. Read after `.claude/docs/architecture-primer.md`.
> Rationale: `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

The checked-in current-state system spec lives here.
MD

  cat > "$repo/docs/architecture-decisions/004-dedicated-local-runtime-service.md" <<'MD'
# ADR-004

> Doc role: `canonical-rationale`
> Status: Accepted rationale. This is not the current-state spec. Read after `.claude/docs/architecture-primer.md` and `docs/ARCHITECTURE.md`.

This file explains why the current boundary exists.
MD

  cat > "$repo/AGENT_CHANGELOG.md" <<'MD'
# Agent Changelog

> Doc role: `recent-deltas`
> Status: Recent deltas only. This file is not the current architecture spec.
> Archive: `docs/archive/architecture-history/agent-changelog-history.md`

Keep only the retired seams that still matter for current agent work.
MD

  cat > "$repo/CLAUDE.md" <<'MD'
# CLAUDE

> Doc role: `task-runbook`
> Status: Workflow and command guide only. For architecture, start at `.claude/docs/architecture-primer.md`.
MD

  cat > "$repo/.claude/docs/README.md" <<'MD'
# Agent Docs

> Doc role: `task-runbook`
> Status: Routing table only. For architecture, start at `.claude/docs/architecture-primer.md`.
MD

  cat > "$repo/.claude/docs/debugging-guide.md" <<'MD'
# Debugging Guide

> Doc role: `task-runbook`
> Status: Debugging runbook only. Use `.claude/docs/architecture-primer.md` for architecture context.
MD

  cat > "$repo/.claude/docs/gotchas.md" <<'MD'
# Gotchas

> Doc role: `task-runbook`
> Status: Implementation hazards only. Use `.claude/docs/architecture-primer.md` for architecture context.
MD

  cat > "$repo/.claude/docs/release-guide.md" <<'MD'
# Release Guide

> Doc role: `task-runbook`
> Status: Release mechanics only. Use `.claude/docs/architecture-primer.md` for architecture context.
MD

  cat > "$repo/docs/audits/sample/AUDIT.md" <<'MD'
# Sample Audit

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

Audit evidence.
MD

  cat > "$repo/docs/manual-qa/sample-closeout.md" <<'MD'
# Sample Manual QA

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

Manual QA evidence.
MD

  cat > "$repo/docs/plans/sample/HANDOFF.md" <<'MD'
# Sample Plan

> Doc role: `historical-evidence`
> Status: Historical evidence only. Do not treat this as the current architecture spec.

Planning evidence.
MD

  cat > "$repo/docs/archive/architecture-history/legacy-architecture.md" <<'MD'
# Legacy Architecture

> Doc role: `historical-evidence`
> Status: Archived. Historical evidence only. Do not treat this as the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

Superseded architecture narrative.
MD

  cat > "$repo/docs/archive/architecture-history/agent-changelog-history.md" <<'MD'
# Agent Changelog History

> Doc role: `historical-evidence`
> Status: Archived. Historical evidence only. Do not treat this as the current architecture spec.
> Current read path: `.claude/docs/architecture-primer.md` -> `docs/ARCHITECTURE.md` -> `docs/architecture-decisions/004-dedicated-local-runtime-service.md`

Older delta history.
MD
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
  [ -f "$temp_root/repo/.verifier/canonical-claims.yaml" ]
  [ -f "$temp_root/repo/.verifier/ledger.yaml" ]
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
    PYTHON_BIN="$(command -v python3)" \
    VENV_DIR="$fake_venv" \
    VERIFY_SKIP_PYTHON_DEPS=1 \
    APALACHE_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    APALACHE_VERSION="9.9.9" \
    APALACHE_REPO="example/apalache" \
    "$PROJECT_ROOT/scripts/verify/install-deps.sh"
  [ "$status" -eq 0 ]

  expected_url="https://github.com/example/apalache/releases/download/v9.9.9/apalache.tgz"
  actual_url="$(cat "$fake_home/requested-url.txt")"
  [ "$actual_url" = "$expected_url" ]
  [ -x "$fake_home/.local/bin/apalache-mc" ]
}

@test "install-deps fails when the Apalache archive checksum does not match" {
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
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    *)
      shift
      ;;
  esac
done
printf 'bad-archive' > "$out"
SH
  chmod +x "$fake_bin/curl"

  run env \
    HOME="$fake_home" \
    PATH="$fake_bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    PYTHON_BIN="$PROJECT_ROOT/.verifier/.venv/bin/python" \
    VENV_DIR="$fake_venv" \
    VERIFY_SKIP_PYTHON_DEPS=1 \
    APALACHE_VERSION="9.9.9" \
    APALACHE_REPO="example/apalache" \
    APALACHE_SHA256="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" \
    "$PROJECT_ROOT/scripts/verify/install-deps.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *'checksum mismatch'* ]]
}

@test "layer1 allows raw tmux commands inside the declared owner" {
  fixture="$PROJECT_ROOT/tests/verify/fixtures/basic-repo"
  run_verify --repo-root "$fixture" --layers 1 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
  [[ "$output" == *'"run_manifest":'* ]]
  [[ "$output" == *'"claim_coverage":'* ]]
}

@test "verify defaults JSON helper scripts to the verifier venv when available" {
  fixture="$PROJECT_ROOT/tests/verify/fixtures/basic-repo"
  fake_bin="$(mktemp -d)"
  marker="$fake_bin/python3-used.txt"

  cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'used\n' > "$MARKER_PATH"
echo "unexpected system python3 invocation" >&2
exit 91
SH
  chmod +x "$fake_bin/python3"

  run env \
    MARKER_PATH="$marker" \
    PATH="$fake_bin:$PATH" \
    VENV_DIR="$TEST_VENV_DIR" \
    "$VERIFY" --repo-root "$fixture" --layers 1 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
  [ ! -f "$marker" ]
}

@test "layer1 fails when raw tmux commands appear outside the declared owner" {
  fixture="$PROJECT_ROOT/tests/verify/fixtures/violations"
  run_verify --repo-root "$fixture" --layers 1 --json
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
  fixture="$PROJECT_ROOT/tests/verify/fixtures/shadow-module"
  run_verify --repo-root "$fixture" --layers 1 --json
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

@test "layer1 recursive files_matching globs select nested swift paths" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier" "$repo/apps/swift/Sources/Capacitor/Models"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership:
  - rule: nested_swift_selector
    description: Nested Swift source files should stay in scope.
    constraint:
      files_matching:
        - apps/swift/Sources/**/*.swift
      must_not: contains_regex:fetchRuntimeConfig
boundaries: []
patterns: []
migration: []
YAML

  cat > "$repo/apps/swift/Sources/Capacitor/Models/BadLauncher.swift" <<'SWIFT'
struct BadLauncher {
    func run() {
        _ = fetchRuntimeConfig()
    }
}
SWIFT

  run_verify --repo-root "$repo" --layers 1 --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] == 1, payload
violation = payload["layer_results"]["1"]["violations"][0]
assert violation["rule"] == "nested_swift_selector", violation
assert violation["path"] == "apps/swift/Sources/Capacitor/Models/BadLauncher.swift", violation
PY
  [ "$status" -eq 0 ]
}

@test "layer1 detects split-string tmux command evasion through process_exec facts" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier" "$repo/src"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership: []
boundaries:
  - rule: tmux_process_exec_owner
    description: Raw tmux execution must be caught even when strings are split.
    constraint:
      files_matching:
        - src/**/*.swift
      must_not: process_exec:^tmux\s
patterns: []
migration: []
YAML

  cat > "$repo/src/BadLauncher.swift" <<'SWIFT'
struct BadLauncher {
    func launch() {
        let command = "tmux " + "new-session -A -s capacitor"
        runScript(command)
    }
}
SWIFT

  run_verify --repo-root "$repo" --layers 1 --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] == 1, payload
rules = {violation["rule"] for violation in payload["layer_results"]["1"]["violations"]}
assert rules == {"tmux_process_exec_owner"}, rules
PY
  [ "$status" -eq 0 ]
}

@test "comment-only legacy symbol mentions do not violate identifier_ref rules" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier" "$repo/src"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership:
  - rule: legacy_symbol_comment_safe
    description: Comments should not trip identifier-only bans.
    constraint:
      files_matching:
        - src/**/*.swift
      must_not: identifier_ref:fetchRuntimeConfig
boundaries: []
patterns: []
migration: []
YAML

  cat > "$repo/src/CommentOnly.swift" <<'SWIFT'
struct CommentOnly {
    // fetchRuntimeConfig used to live here before the runtime boundary cleanup.
}
SWIFT

  run_verify --repo-root "$repo" --layers 1 --json
  [ "$status" -eq 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["passed"] is True, payload
assert payload["violation_count"] == 0, payload
assert payload["layer_results"]["1"]["violations"] == [], payload
PY
  [ "$status" -eq 0 ]
}

@test "changed-only still catches unchanged violations when verifier config changes" {
  repo="$(new_temp_repo)"
  init_git_repo "$repo"
  mkdir -p "$repo/.verifier" "$repo/src"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership: []
boundaries: []
patterns: []
migration: []
YAML

  cat > "$repo/src/BadLauncher.swift" <<'SWIFT'
struct BadLauncher {
    let command = "tmux new-session -A -s capacitor"
}
SWIFT

  commit_repo "$repo"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership: []
boundaries:
  - rule: tmux_router_exclusive_command_owner
    description: TmuxRouter is the only module allowed to build raw tmux commands.
    constraint:
      files_matching:
        - src/**/*.swift
      must_not: shell_command_literal:^tmux\s
patterns: []
migration: []
YAML

  run_verify --repo-root "$repo" --layers 1 --changed-only --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["passed"] is False, payload
assert payload["violation_count"] == 1, payload
assert payload.get("selected_scope") == "full_due_to_verifier_change", payload
rules = {violation["rule"] for violation in payload["layer_results"]["1"]["violations"]}
assert rules == {"tmux_router_exclusive_command_owner"}, rules
PY
  [ "$status" -eq 0 ]
}

@test "evolve generates an architecture packet with primer spec and ADR as the canonical read path" {
  repo="$(new_temp_repo)"
  write_doc_governance_fixture "$repo"

  run_verify --repo-root "$repo" --layers 1 --evolve --json
  [ "$status" -eq 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/architecture-packet.md"
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text()

assert "> Doc role: `generated-aid`" in text, text
assert "## Canonical Read Path" in text, text
assert "1. `.claude/docs/architecture-primer.md`" in text, text
assert "2. `docs/ARCHITECTURE.md`" in text, text
assert "3. `docs/architecture-decisions/004-dedicated-local-runtime-service.md`" in text, text
assert "## Recent Deltas" in text, text
assert "`AGENT_CHANGELOG.md`" in text, text

canonical_section = text.split("## Canonical Read Path", 1)[1].split("## Recent Deltas", 1)[0]
assert "AGENT_CHANGELOG.md" not in canonical_section, canonical_section
PY
  [ "$status" -eq 0 ]
}

@test "evolve fails when a non-canonical runbook claims architecture authority" {
  repo="$(new_temp_repo)"
  write_doc_governance_fixture "$repo"

  cat > "$repo/.claude/docs/debugging-guide.md" <<'MD'
# Debugging Guide

> Doc role: `task-runbook`
> Status: Debugging runbook only. Use `.claude/docs/architecture-primer.md` for architecture context.

Architecture source of truth lives in `docs/ARCHITECTURE.md`.
MD

  run_verify --repo-root "$repo" --layers 1 --evolve --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
rules = {violation["rule"] for violation in payload["layer_results"]["1"]["violations"]}
assert "non_canonical_doc_claims_architecture_authority" in rules, rules
PY
  [ "$status" -eq 0 ]
}

@test "evolve fails when an archived architecture doc is missing the archived header" {
  repo="$(new_temp_repo)"
  write_doc_governance_fixture "$repo"

  cat > "$repo/docs/archive/architecture-history/legacy-architecture.md" <<'MD'
# Legacy Architecture

Superseded architecture narrative without an archive banner.
MD

  run_verify --repo-root "$repo" --layers 1 --evolve --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
rules = {violation["rule"] for violation in payload["layer_results"]["1"]["violations"]}
assert "archived_doc_missing_historical_header" in rules, rules
PY
  [ "$status" -eq 0 ]
}

@test "layer crashes produce error JSON instead of reusing stale green reports" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier" "$repo/src"

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership:
  - rule: clean_repo
    description: Clean repo should pass.
    constraint:
      files_matching:
        - src/**/*.swift
      must_not: contains_regex:fetchRuntimeConfig
boundaries: []
patterns: []
migration: []
YAML

  cat > "$repo/src/Clean.swift" <<'SWIFT'
struct Clean {}
SWIFT

  run_verify --repo-root "$repo" --layers 1 --json
  [ "$status" -eq 0 ]

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs: []
ownership:
  - rule: explode
    description: Invalid fact kinds should fail the verifier closed.
    constraint:
      files_matching:
        - src/**/*.swift
      must_not: not_a_fact_kind:boom
boundaries: []
patterns: []
migration: []
YAML

  run_verify --repo-root "$repo" --layers 1 --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/layer1.json" "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

layer = json.loads(pathlib.Path(sys.argv[1]).read_text())
final = json.loads(pathlib.Path(sys.argv[2]).read_text())

assert layer["status"] == "error", layer
assert layer["passed"] is False, layer
assert layer["execution_error"], layer
assert final["passed"] is False, final
assert final["layer_results"]["1"]["status"] == "error", final
PY
  [ "$status" -eq 0 ]
}

@test "layer2 behavioral specs parse and execute when Apalache is installed" {
  if ! command -v apalache-mc >/dev/null 2>&1; then
    skip "apalache-mc is not installed"
  fi

  run_verify --repo-root "$PROJECT_ROOT" --layers 2 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
  [[ "$output" == *'"spec_results":'* ]]
}

@test "verifier shell helpers default to the verifier venv python" {
  repo="$(new_temp_repo)"
  fake_bin="$(mktemp -d)"

  cat > "$fake_bin/python3" <<'SH'
#!/usr/bin/env bash
echo "unexpected system python invocation" >&2
exit 97
SH
  chmod +x "$fake_bin/python3"

  run env VENV_DIR="$TEST_VENV_DIR" "$VERIFY" --repo-root "$repo" --bootstrap
  [ "$status" -eq 0 ]

  run env PATH="$fake_bin:$PATH" VENV_DIR="$TEST_VENV_DIR" "$VERIFY" --repo-root "$repo" --layers 1 --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"passed": true'* ]]
}

@test "report-only preserves findings but exits zero" {
  fixture="$PROJECT_ROOT/tests/verify/fixtures/violations"
  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$fixture" --layers 1 --report-only --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"violation_count":'* ]]
  [[ "$output" == *'"tmux_router_exclusive_command_owner"'* ]]
}

@test "changed-only rejects layer2 path-scoped runs" {
  run env VENV_DIR="$PROJECT_ROOT/.verifier/.venv" "$VERIFY" --repo-root "$PROJECT_ROOT" --layers 1,2 --changed-only
  [ "$status" -eq 2 ]
  [[ "$output" == *'Layer 2 does not support path-scoped runs'* ]]
}

@test "comment-satisfied HookSetup proofs fail when executable proof artifacts are missing" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier/specs" "$repo/core/capacitor-core/src" "$repo/fake-bin"

  cat > "$repo/.verifier/specs/_helpers.py" <<'PY'
def contract(rule, proofs, tla_specs=None):
    return {"rule": rule, "proofs": proofs, "tla_specs": tla_specs or []}
PY

  cat > "$repo/.verifier/specs/HookSetupContracts.py" <<'PY'
from _helpers import contract

def contracts():
    return [contract("hook_setup_contracts", proofs=["hook_setup_relative_symlink"])]
PY

  cat > "$repo/.verifier/specs/proof_registry.yaml" <<'YAML'
proofs:
  hook_setup_relative_symlink:
    language: rust
    path: core/capacitor-core/src/runtime_setup.rs
    symbol: test_verify_hook_binary_accepts_relative_symlink_target
    command:
      - cargo
      - test
      - -p
      - capacitor-core
      - test_verify_hook_binary_accepts_relative_symlink_target
      - --
      - --exact
      - --nocapture
tla_specs: {}
YAML

  cat > "$repo/core/capacitor-core/src/runtime_setup.rs" <<'RUST'
// fn test_verify_hook_binary_accepts_relative_symlink_target() {}
pub fn runtime_setup_contract() {}
RUST

  cat > "$repo/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$repo/fake-bin/cargo"

  run env PATH="$repo/fake-bin:$PATH" VENV_DIR="$TEST_VENV_DIR" "$VERIFY" --repo-root "$repo" --layers 2 --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] >= 1, payload
rules = {violation["rule"] for violation in payload["layer_results"]["2"]["violations"]}
assert "hook_setup_contracts" in rules, rules
PY
  [ "$status" -eq 0 ]
}

@test "TerminalActivationCoordinator semantic breaks fail through executable Swift proofs" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier/specs" "$repo/apps/swift/Tests/CapacitorTests" "$repo/fake-bin"

  cat > "$repo/.verifier/specs/_helpers.py" <<'PY'
def contract(rule, proofs, tla_specs=None):
    return {"rule": rule, "proofs": proofs, "tla_specs": tla_specs or []}
PY

  cat > "$repo/.verifier/specs/RuntimeBoundaryContracts.py" <<'PY'
from _helpers import contract

def contracts():
    return [contract("terminal_activation_coordinator_contracts", proofs=["terminal_activation_arbitration"])]
PY

  cat > "$repo/.verifier/specs/proof_registry.yaml" <<'YAML'
proofs:
  terminal_activation_arbitration:
    language: swift
    path: apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift
    symbol: testLaunchTerminalRequestArbitrationScenarios
    command:
      - swift
      - test
      - --package-path
      - apps/swift
      - --filter
      - TerminalLauncherTests/testLaunchTerminalRequestArbitrationScenarios
tla_specs: {}
YAML

  cat > "$repo/apps/swift/Tests/CapacitorTests/TerminalLauncherTests.swift" <<'SWIFT'
import XCTest

final class TerminalLauncherTests: XCTestCase {
    func testLaunchTerminalRequestArbitrationScenarios() async {}
}
SWIFT

  cat > "$repo/fake-bin/swift" <<'SH'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -q 'TerminalLauncherTests/testLaunchTerminalRequestArbitrationScenarios'; then
  echo "terminal activation regression" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$repo/fake-bin/swift"

  run env PATH="$repo/fake-bin:$PATH" VENV_DIR="$TEST_VENV_DIR" "$VERIFY" --repo-root "$repo" --layers 2 --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] >= 1, payload
rules = {violation["rule"] for violation in payload["layer_results"]["2"]["violations"]}
assert "terminal_activation_coordinator_contracts" in rules, rules
PY
  [ "$status" -eq 0 ]
}

@test "replay fixtures with absurd shell_count fail through replay diff executable proofs" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier/specs" "$repo/core/capacitor-core/tests/fixtures/replay" "$repo/core/capacitor-core/tests" "$repo/fake-bin"

  cat > "$repo/.verifier/specs/_helpers.py" <<'PY'
def contract(rule, proofs, tla_specs=None):
    return {"rule": rule, "proofs": proofs, "tla_specs": tla_specs or []}
PY

  cat > "$repo/.verifier/specs/ReplayParityContracts.py" <<'PY'
from _helpers import contract

def contracts():
    return [contract("replay_parity_contracts", proofs=["replay_diff_corpus"])]
PY

  cat > "$repo/.verifier/specs/proof_registry.yaml" <<'YAML'
proofs:
  replay_diff_corpus:
    language: rust
    path: core/capacitor-core/tests/replay_diff.rs
    symbol: replay_diff_corpus_matches_expected_and_is_deterministic
    command:
      - cargo
      - test
      - -p
      - capacitor-core
      - --test
      - replay_diff
      - replay_diff_corpus_matches_expected_and_is_deterministic
tla_specs: {}
YAML

  cat > "$repo/core/capacitor-core/tests/replay_diff.rs" <<'RUST'
#[test]
fn replay_diff_corpus_matches_expected_and_is_deterministic() {}

#[test]
fn replay_diff_shadow_snapshot_read_model_matches_runtime_snapshot() {}
RUST

  cat > "$repo/core/capacitor-core/tests/fixtures/replay/absurd.json" <<'JSON'
{
  "name": "absurd-shell-count",
  "events": [
    {
      "kind": "hook_event"
    }
  ],
  "expected": {
    "events_ingested": 1,
    "shell_count": 999
  }
}
JSON

  cat > "$repo/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
if grep -R '"shell_count"[[:space:]]*:[[:space:]]*999' "$PWD/core/capacitor-core/tests/fixtures/replay" >/dev/null; then
  echo "replay shell count mismatch" >&2
  exit 1
fi
exit 0
SH
  chmod +x "$repo/fake-bin/cargo"

  run env PATH="$repo/fake-bin:$PATH" VENV_DIR="$TEST_VENV_DIR" "$VERIFY" --repo-root "$repo" --layers 2 --json
  [ "$status" -ne 0 ]

  run python3 - <<'PY' "$repo/.verifier/reports/last-run.json"
import json
import pathlib
import sys

payload = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert payload["violation_count"] >= 1, payload
rules = {violation["rule"] for violation in payload["layer_results"]["2"]["violations"]}
assert "replay_parity_contracts" in rules, rules
PY
  [ "$status" -eq 0 ]
}

@test "evolve fails when a canonical doc claim is not covered by a verifier rule" {
  fixture="$PROJECT_ROOT/tests/verify/fixtures/wrappers"
  run_verify --repo-root "$fixture" --layers 1 --evolve --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'uncovered_doc_claim'* ]]
}

@test "evolve fails when a structural rule references a missing claim id" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier" "$repo/docs" "$repo/src"

  cat > "$repo/docs/ARCHITECTURE.md" <<'MD'
VERIFIER_CLAIM(existing_claim): owner_scope=src/RuntimeClient.swift; RuntimeClient owns the boundary.
MD

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs:
    - docs/ARCHITECTURE.md
ownership:
  - rule: missing_claim_binding
    description: Missing claim ids should fail evolve.
    claim_ids:
      - missing_claim
    constraint:
      all_modules: true
      must_not: path_regex:^does-not-exist$
boundaries: []
patterns: []
migration: []
YAML

  run_verify --repo-root "$repo" --layers 1 --evolve --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'missing_claim_id'* ]]
}

@test "evolve fails when a canonical claim owner scope matches no modules" {
  repo="$(new_temp_repo)"
  mkdir -p "$repo/.verifier" "$repo/docs" "$repo/src"

  cat > "$repo/docs/ARCHITECTURE.md" <<'MD'
VERIFIER_CLAIM(orphaned_claim): owner_scope=src/MissingOwner.swift; MissingOwner owns this boundary.
MD

  cat > "$repo/.verifier/structural.yaml" <<'YAML'
meta:
  canonical_docs:
    - docs/ARCHITECTURE.md
ownership:
  - rule: orphaned_claim_binding
    description: Owner scope drift should fail evolve.
    claim_ids:
      - orphaned_claim
    constraint:
      all_modules: true
      must_not: path_regex:^does-not-exist$
boundaries: []
patterns: []
migration: []
YAML

  cat > "$repo/src/RuntimeClient.swift" <<'SWIFT'
struct RuntimeClient {}
SWIFT

  run_verify --repo-root "$repo" --layers 1 --evolve --json
  [ "$status" -ne 0 ]
  [[ "$output" == *'orphaned_claim_owner_scope'* ]]
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

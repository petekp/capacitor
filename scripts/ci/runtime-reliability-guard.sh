#!/bin/bash
# Runtime reliability guard — enforces ratchet budgets for the holistic reliability program.
# Run: bash scripts/ci/runtime-reliability-guard.sh [--status]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-run}"
SELF_PATH="scripts/ci/runtime-reliability-guard.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

FAILURES=0

check_budget() {
    local name="$1"
    local pattern="$2"
    local budget="$3"
    local path="${4:-.}"

    local count
    count="$(grep -rn "$pattern" "$path" --include='*.rs' --include='*.swift' --include='*.sh' --include='*.bats' 2>/dev/null | grep -v '/.claude/' | grep -v "$SELF_PATH" | grep -v 'target/' | grep -v '.worktrees/' | wc -l)"
    count="${count##* }"
    count="${count:-0}"

    if [ "$count" -gt "$budget" ]; then
        printf "${RED}FAIL${NC} %-45s count=%d budget=%d (+%d)\n" "$name" "$count" "$budget" "$((count - budget))"
        FAILURES=$((FAILURES + 1))
    elif [ "$count" -eq "$budget" ]; then
        printf "${YELLOW}AT BUDGET${NC} %-40s count=%d budget=%d\n" "$name" "$count" "$budget"
    else
        printf "${GREEN}OK${NC} %-47s count=%d budget=%d (-%d)\n" "$name" "$count" "$budget" "$((budget - count))"
    fi
}

check_denylist() {
    local name="$1"
    local pattern="$2"
    local path="${3:-.}"

    local count
    count="$(grep -rn "$pattern" "$path" --include='*.rs' --include='*.swift' --include='*.sh' --include='*.bats' 2>/dev/null | grep -v '/.claude/' | grep -v "$SELF_PATH" | grep -v 'target/' | grep -v '.worktrees/' | wc -l)"
    count="${count##* }"
    count="${count:-0}"

    if [ "$count" -gt 0 ]; then
        printf "${RED}DENYLIST${NC} %-42s count=%d (should be 0)\n" "$name" "$count"
        FAILURES=$((FAILURES + 1))
    else
        printf "${GREEN}CLEAR${NC} %-44s count=0\n" "$name"
    fi
}

check_path_absent() {
    local name="$1"
    local path="$2"

    if [ -e "$path" ]; then
        printf "${RED}DENYLIST${NC} %-42s path=%s\n" "$name" "$path"
        FAILURES=$((FAILURES + 1))
    else
        printf "${GREEN}CLEAR${NC} %-44s path absent\n" "$name"
    fi
}

check_file_contains() {
    local name="$1"
    local path="$2"
    local pattern="$3"

    if grep -q -- "$pattern" "$path"; then
        printf "${GREEN}WIRED${NC} %-44s pattern present\n" "$name"
    else
        printf "${RED}MISSING${NC} %-42s path=%s pattern=%s\n" "$name" "$path" "$pattern"
        FAILURES=$((FAILURES + 1))
    fi
}

check_file_lacks() {
    local name="$1"
    local path="$2"
    local pattern="$3"

    if grep -q "$pattern" "$path"; then
        printf "${RED}DENYLIST${NC} %-42s path=%s pattern=%s\n" "$name" "$path" "$pattern"
        FAILURES=$((FAILURES + 1))
    else
        printf "${GREEN}CLEAR${NC} %-44s pattern absent\n" "$name"
    fi
}

echo "═══════════════════════════════════════════════════════════════"
echo "  Runtime Reliability Guard"
echo "═══════════════════════════════════════════════════════════════"
echo ""

echo "── Legacy HTTP Hook Ratchets ──"
echo ""

check_budget "managed command hook creation"   '"command"\.to_string()'            3  "core/"
check_budget "stdin reading in handle.rs"      'stdin'                             0  "core/hud-hook/src/handle.rs"
check_budget "Commands::Handle"                'Handle'                            0  "core/hud-hook/src/main.rs"
check_budget "handle::run() caller"            'handle::run()'                     0  "core/hud-hook/src/main.rs"
check_budget "register_http_hooks_in_settings" 'register_http_hooks_in_settings'   0  "core/"
check_budget "install_http_hooks FFI"          'install_http_hooks'                0
check_budget "installHttpHooks Swift"          'installHttpHooks'                  0  "apps/"
check_budget "didInstallHttpHooks flag"        'didInstallHttpHooks'               0  "apps/"
check_budget "installHttpHooksIfNeeded"        'installHttpHooksIfNeeded'          0  "apps/"
check_budget "async_hook in hook creation"     'async_hook.*Some.*true'            0  "core/capacitor-core/"
check_budget "HOOK_TIMEOUT_SECONDS"            'HOOK_TIMEOUT_SECONDS'              0  "core/"

echo ""
echo "── Holistic Reliability Ratchets ──"
echo ""

# Calibrated baseline counts as of 2026-03-05 (must only go down)
check_budget "Setup fatalError path"           'fatalError("Failed to create CoreRuntime")' 0 "apps/swift/Sources/Capacitor/Models/SetupRequirements.swift"
check_budget "verify_hook_binary handle arg"   'arg("handle")'                                0 "core/capacitor-core/src/runtime_setup.rs"
check_budget "hook_types CLAUDE_PROJECT_DIR fallback" 'std::env::var("CLAUDE_PROJECT_DIR")'  0 "core/hud-hook/src/hook_types.rs"
check_budget "hook_types PWD fallback"         'std::env::var("PWD")'                          0 "core/hud-hook/src/hook_types.rs"
check_budget "HookServer waitUntilExit"        'waitUntilExit()'                               0 "apps/swift/Sources/Capacitor/Models/HookServerManager.swift"
check_budget "ProjectDetails waitUntilExit"    'waitUntilExit()'                               2 "apps/swift/Sources/Capacitor/Models/ProjectDetailsManager.swift"
check_budget "Terminal outputData append"      'outputData\.append('                           2 "apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift"
check_budget "AppState dragdrop group.leave"   'group\.leave()'                                1 "apps/swift/Sources/Capacitor/Models/AppState.swift"
check_budget "SessionStateManager global metadata fallback" 'if stabilized == merged'          0 "apps/swift/Sources/Capacitor/Models/SessionStateManager.swift"
check_budget "Session tests fixed 2026 dates"  '2026-02-28'                                    0 "apps/swift/Tests/CapacitorTests/SessionStateManagerTests.swift"
check_budget "hud-hook runtime client local transport" 'LocalRuntimeHost|RuntimeTransport::Local|InProcessSnapshot|ExternalServicePrototype' 0 "core/hud-hook/src/runtime_client.rs"
check_budget "Swift runtime client core_snapshot labels" 'core_snapshot' 0 "apps/swift/Sources/Capacitor/Models/RuntimeClient.swift"

echo ""
echo "── Denylist (should always be 0) ──"
echo ""

check_denylist "installHttpHooks in Swift"      'installHttpHooks'     "apps/"
check_denylist "didInstallHttpHooks in Swift"   'didInstallHttpHooks'  "apps/"
check_denylist "install_http_hooks FFI"         'install_http_hooks'
check_denylist "App.swift concrete debug windows" 'DebugProjectListPanel|UITuningPanelMenuButton|ProjectDebugPanelMenuButton|UITuningPanel\(' "apps/swift/Sources/Capacitor/App.swift"
check_denylist "ProjectsView concrete debug cards" 'DebugActiveStateCard|DebugActivationTraceCard|debugShowProjectListDiagnostics' "apps/swift/Sources/Capacitor/Views/Projects/ProjectsView.swift"
check_denylist "WelcomeView setup preview internals" 'debugScenario|\.preview\(' "apps/swift/Sources/Capacitor/Views/Setup/WelcomeView.swift"
check_path_absent "Debug-owned GlassConfig path" "apps/swift/Sources/Capacitor/Views/Debug/UITuningPanel/GlassConfig.swift"
check_file_contains "Architecture doc service title" "docs/ARCHITECTURE.md" 'Dedicated Runtime Service'
check_file_contains "Release matrix service scope" "docs/SESSION_STATE_RELEASE_MATRIX.md" 'Runtime Service + Operations'
check_file_lacks "Architecture doc snapshot title" "docs/ARCHITECTURE.md" 'Runtime-Snapshot Model'
check_file_lacks "Architecture doc no-process claim" "docs/ARCHITECTURE.md" 'No separate runtime process boundary'
check_file_lacks "Architecture doc socket removal claim" "docs/ARCHITECTURE.md" 'socket process removed'
check_file_lacks "Release matrix snapshot architecture wording" "docs/SESSION_STATE_RELEASE_MATRIX.md" 'runtime-snapshot architecture'

echo ""
echo "── Operational Verification Wiring ──"
echo ""

check_file_contains "CI runtime reliability gate" ".github/workflows/ci.yml" 'scripts/ci/runtime-reliability.sh ci'
check_file_contains "Nightly runtime reliability suite" ".github/workflows/runtime-reliability-nightly.yml" 'scripts/ci/runtime-reliability.sh nightly'
check_file_contains "Runtime reliability wraps reliability guard" "scripts/ci/runtime-reliability.sh" 'scripts/ci/runtime-reliability-guard.sh --status'
check_file_contains "Runtime reliability wraps replay gate" "scripts/ci/runtime-reliability.sh" 'scripts/ci/session-state-gate.sh'
check_file_contains "AX verifier script keeps allow-untrusted mode" "scripts/ci/ax-automation-verify.sh" '--allow-untrusted'
check_file_contains "AX verifier script keeps log-health mode" "scripts/ci/ax-automation-verify.sh" '--require-log-health'
check_file_contains "Runtime reliability defines AX verifier ci lane" "scripts/ci/runtime-reliability.sh" 'run_ax_verifier_ci'
check_file_contains "Runtime reliability defines AX verifier nightly lane" "scripts/ci/runtime-reliability.sh" 'run_ax_verifier_nightly'
check_file_contains "Runtime reliability prepares AX release build" "scripts/ci/runtime-reliability.sh" 'cargo build -p capacitor-core -p hud-hook --release'
check_file_contains "AX contract ship checklist references verifier" "docs/plans/ax-automation-contract/SHIP_CHECKLIST.md" 'scripts/ci/ax-automation-verify.sh'
check_file_contains "Runtime reliability wraps projection parity gate" "scripts/ci/runtime-reliability.sh" 'replay_diff_projection_read_model_matches_runtime_snapshot'
check_file_contains "Nightly workflow keeps schedule trigger" ".github/workflows/runtime-reliability-nightly.yml" 'schedule:'

echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ "$FAILURES" -gt 0 ]; then
    printf "${RED}$FAILURES ratchet(s) exceeded${NC}\n"
    exit 1
else
    if [ "$MODE" = "--status" ]; then
        printf "${GREEN}Status clean: all ratchets within budget${NC}\n"
    else
        printf "${GREEN}All ratchets within budget${NC}\n"
    fi
fi

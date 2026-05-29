#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
workspace_root="$(cd "${script_dir}/../.." && pwd -P)"
cd "${workspace_root}"

package_path="apps/swift"

# Six suites flake when run together in the same `swift test` process. The root
# cause is cross-suite MainActor / shared-state leakage (e.g. global singletons
# and @MainActor statics that one suite mutates and another reads). Running them
# in a single shared process makes them flake together; running each in its own
# fresh `swift test --filter` process eliminates the cross-suite leakage.
#
# Coverage is fully preserved: the broad run executes everything EXCEPT these
# six, and the isolated loop runs each of the six on its own. Every test still
# runs exactly once per CI invocation.
#
# FOLLOW-UP (code, separate from CI config): the underlying shared-state races
# should be fixed at the source (proper per-test isolation / dependency
# injection) so these suites can rejoin the broad run. Tracked outside this lane.
ISOLATED_SUITES=(
  AppStateWorkBatchOpenTests
  HookServerManagerTests
  IdeaCapturePopoverTests
  MacOSPreviewWorkProofTests
  SessionSummarizerTests
  TerminalLauncherTests
)

echo "[swift-test] broad run (skipping cross-suite-flaky suites)"
broad_skip_args=()
for suite in "${ISOLATED_SUITES[@]}"; do
  broad_skip_args+=(--skip "$suite")
done
swift test --package-path "$package_path" "${broad_skip_args[@]}"

for suite in "${ISOLATED_SUITES[@]}"; do
  echo ""
  echo "[swift-test] isolated run: ${suite} (fresh process)"
  swift test --package-path "$package_path" --filter "$suite"
done

echo ""
echo "[swift-test] all suites passed (broad + isolated)."

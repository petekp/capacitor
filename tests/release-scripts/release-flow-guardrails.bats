#!/usr/bin/env bats

# Guardrail tests for release flow scripts.
# These are intentionally lightweight source checks that prevent
# regressions in release defaults and shell safety behavior.

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "build-distribution defaults to alpha channel" {
    run grep -En '^CHANNEL="alpha"$' "$PROJECT_ROOT/scripts/release/build-distribution.sh"
    [ "$status" -eq 0 ]
}

@test "release workflow forwards channel explicitly to build-distribution" {
    run grep -En 'BUILD_ARGS\+=\(--channel "\$CHANNEL"\)' "$PROJECT_ROOT/scripts/release/release.sh"
    [ "$status" -eq 0 ]
}

@test "verify-app-bundle does not use post-increment in fail/warn helpers" {
    run grep -En 'ERRORS\+\+|WARNINGS\+\+' "$PROJECT_ROOT/scripts/release/verify-app-bundle.sh"
    [ "$status" -eq 1 ]
}

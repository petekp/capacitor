#!/usr/bin/env bats

setup() {
    PROJECT_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "restart-app has alpha/stable fallback defaults" {
    run grep -F 'CHANNEL="${CHANNEL:-alpha}"' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]

    run grep -F 'PROFILE="${PROFILE:-stable}"' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]
}

@test "restart-app can load persisted runtime context" {
    run grep -En 'CAPACITOR_RUNTIME_STATE_FILE|runtime-context\\.env|CAPACITOR_RUNTIME_CHANNEL|CAPACITOR_RUNTIME_PROFILE' \
        "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]
}

@test "restart-app help documents profile flags" {
    run grep -En -- '--profile <stable\\|frontier>' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]

    run grep -En -- '--frontier' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]
}

@test "restart-app enforces alpha-only channel unless bypass is set" {
    run grep -En 'CAPACITOR_ALLOW_NON_ALPHA' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]

    run grep -F '"$CHANNEL" != "alpha"' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]
}

@test "restart-app writes CapacitorProfile into debug app Info.plist" {
    run grep -En 'CapacitorProfile' "$PROJECT_ROOT/scripts/dev/restart-app.sh"
    [ "$status" -eq 0 ]
}

@test "stable wrapper invokes restart-app with alpha stable args" {
    run grep -F -- '--channel alpha --profile stable' \
        "$PROJECT_ROOT/scripts/dev/restart-alpha-stable.sh"
    [ "$status" -eq 0 ]
}

@test "frontier wrapper invokes restart-app with alpha frontier args" {
    run grep -F -- '--channel alpha --profile frontier' \
        "$PROJECT_ROOT/scripts/dev/restart-alpha-frontier.sh"
    [ "$status" -eq 0 ]
}

@test "current wrapper delegates to restart-app without forcing channel/profile" {
    run grep -F 'exec "$SCRIPT_DIR/restart-app.sh" "$@"' \
        "$PROJECT_ROOT/scripts/dev/restart-current.sh"
    [ "$status" -eq 0 ]
}

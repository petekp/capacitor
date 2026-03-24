#!/usr/bin/env bash
set -euo pipefail

echo "=== Method runner CLI smoke tests ==="

# Test 1: --help still works (exits non-zero but prints usage)
echo "Test 1: --help prints usage..."
HELP_OUTPUT=$(cargo run -p capacitor-core --bin method-runner -- --help 2>&1 || true)
if echo "$HELP_OUTPUT" | grep -q "Usage:"; then
  echo "  PASS"
else
  echo "  FAIL: --help did not print Usage"
  exit 1
fi

# Test 2: normalize with fixture
echo "Test 2: normalize with fixture..."
TMP=$(mktemp -d)
cargo run -p capacitor-core --bin method-runner -- normalize \
  --definition methods/fixtures/minimal-dispatch.yaml \
  --root "$TMP/run1"
test -f "$TMP/run1/.method/definition.snapshot.yaml"
echo "  PASS"

# Test 3: run with fake adapters (default, no --real)
echo "Test 3: run with fake adapters..."
cargo run -p capacitor-core --bin method-runner -- run \
  --definition methods/fixtures/minimal-dispatch.yaml \
  --root "$TMP/run2"
test -f "$TMP/run2/.method/events.ndjson"
echo "  PASS"

# Cleanup
rm -rf "$TMP"

echo "All CLI smoke tests passed"

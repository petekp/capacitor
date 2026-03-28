#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/petepetrash/Code/capacitor"

cd "$ROOT"

echo "== Control plane =="
bash docs/historical/orchestrator-next-slices/guard.sh

echo
echo "== Rust orchestration gates =="
cargo test -p capacitor-core --test delegation_contract
cargo test -p capacitor-core

echo
echo "== Swift orchestration gates =="
swift test --package-path apps/swift --filter 'DelegationLoopManagerTests|IdeaQueueStatusResolverTests|ProjectPrimaryActionResolverTests|RuntimeClientTests|AppStateSessionObservationTests|AppConfigTests'
swift test --package-path apps/swift
swift build --package-path apps/swift

echo
echo "== Residue sweep =="
echo "[ ] All completed-slice residue queries in SLICES.yaml return zero matches"
echo "[ ] No temporary bridge types, migration-only helpers, or TODO/FIXME migration markers remain"
echo "[ ] No new orchestrator code depends on WorkstreamsManager or WorkstreamsPanel"
echo "[ ] Revised orchestrator spec, playbook, charter, translation guide, and decisions all agree on the target architecture"

echo
echo "== Manual-only checks =="
echo "[ ] Reopen a project with an active orchestrator and verify reconnect without duplicate sessions"
echo "[ ] Submit a milestone decision and verify the same worker session resumes"
echo "[ ] Restart the app mid-flight and verify orchestration state reconstructs cleanly"
echo "[ ] Project cards remain comprehensible under active orchestration state"

echo
echo "== Ship decision =="
echo "Ready to ship: yes / no"
echo "Remaining blockers:"
echo "  - <blocker or None>"
echo "Evidence summary:"
echo "  - guard.sh, cargo test, swift test, swift build"

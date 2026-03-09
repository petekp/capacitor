# Capacitor Architecture Charter

## Purpose

Capacitor has one Rust core, one Swift shell, and one small permanent architecture governance surface.

This charter records the enduring constraints that keep the repo coherent.

## Invariants

1. Rust owns domain semantics, persisted runtime truth, and file-backed system behavior.
2. Swift owns rendering, interaction flow, and macOS-specific side effects.
3. Domain policy is not duplicated across Rust and Swift.
4. Live code uses permanent namespaces only.
5. Historical material lives under `docs/archive/`, not in the active repo surface.

## Current Structure

- Rust bounded contexts: `core/capacitor-core/src/contexts/`
- Swift app shell: `apps/swift/Sources/Capacitor/`
- Architecture governance: `architecture/`

## Guardrails

1. `scripts/architecture/check_architecture_guards.sh` must pass in CI.
2. Retired directory surfaces must remain absent.
3. Permanent architectural changes must be reflected in `architecture/DECISIONS.md`.

# ADR-003: Runtime Snapshot Architecture

**Status:** Accepted  
**Date:** 2026-02-28

## Context

Capacitor originally used multiple parallel execution surfaces for state and routing.
That increased drift, duplicated policy, and made debugging difficult.

## Decision

Adopt a single runtime-snapshot architecture:

1. `capacitor-core` is the only domain-policy authority.
2. `hud-hook` is a thin ingest adapter into `capacitor-core`.
3. Swift reads typed runtime snapshots and executes platform effects only.
4. No parallel business logic across Rust and Swift.

## Consequences

Positive:

1. One source of truth for session/project/routing derivation.
2. Simpler failure model and easier debugging.
3. Smaller API surface and fewer translation layers.

Tradeoffs:

1. Rust core changes can impact many app flows at once.
2. FFI contracts must be kept tight and versioned intentionally.

## Operational Guardrails

1. Replay-diff tests lock reducer determinism.
2. AX smoke and release bundle verification gate user-visible flows.
3. Rewrite guards block reintroduction of removed legacy surfaces.

# ADR-003: Runtime Snapshot Architecture

**Status:** Accepted  
**Date:** 2026-02-28

## Context

Capacitor originally used multiple parallel execution surfaces for state and routing.
That increased drift, duplicated policy, and made debugging difficult.

## Decision

Adopt a single runtime-snapshot architecture:

1. `capacitor-core` is the persisted runtime authority for hook ingest, reducer/query policy, and snapshot persistence.
2. `hud-hook` is a thin ingest adapter into `capacitor-core`.
3. Swift reads typed runtime snapshots, then owns deterministic post-snapshot projection, freshness guards, hysteresis, and platform effects.
4. Do not duplicate source-of-truth runtime policy across Rust and Swift; Swift may own deterministic presentation/lifecycle projection without rewriting persisted runtime truth.

## Consequences

Positive:

1. One persisted runtime truth plus one deterministic Swift projection layer for visible session/project/routing state.
2. Simpler failure model and easier debugging.
3. Smaller API surface and fewer translation layers.

Tradeoffs:

1. Rust core changes can impact many app flows at once.
2. FFI contracts must be kept tight and versioned intentionally.

## Operational Guardrails

1. Replay-diff tests lock reducer determinism.
2. AX smoke and release bundle verification gate user-visible flows.
3. Architecture guards block reintroduction of removed legacy surfaces.

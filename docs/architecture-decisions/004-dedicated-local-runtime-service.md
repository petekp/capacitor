# ADR-004: Dedicated Local Runtime Service

**Status:** Accepted  
**Date:** 2026-03-09

## Context

Capacitor's hook and runtime tracking system is core product infrastructure.
The product needs one stable local boundary for tracking, diagnostics, and future feature work.

## Decision

Capacitor uses a dedicated local runtime service as its tracking architecture.

Specifically:

1. The runtime service is the application boundary for tracking.
2. The Swift app becomes a client of the runtime service.
3. Claude ingress adapters and shell signal adapters target the runtime service.
4. Observation journal plus derived read models remain the target runtime model.

## Consequences

Positive:

1. Runtime continuity is no longer tied to the visible app lifecycle.
2. The ownership boundary becomes explicit and easier to preserve as new features are added.
3. Future integrations have one stable local runtime boundary to target.
4. UI feature work is less likely to entangle itself with runtime-host concerns.

Tradeoffs:

1. We reintroduce process lifecycle management and local transport complexity.
2. The service boundary must remain narrow and local, or we risk architectural backsliding.

## Guardrails

1. The runtime service must remain local-only and authenticated.
2. Adapters remain forwarders, not reducers.
3. Runtime verification stays green through replay, smoke, and reliability checks.
4. The process split must be implemented as composition-root work, not by moving domain semantics out of Rust.

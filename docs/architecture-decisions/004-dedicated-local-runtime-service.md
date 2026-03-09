# ADR-004: Dedicated Local Runtime Service

**Status:** Accepted  
**Date:** 2026-03-09

## Context

Capacitor's hook and runtime tracking system is core product infrastructure. We want to begin focusing on new features soon, but we do not want feature growth to make the migration to a sound architecture progressively harder.

The previous rewrite decisions deliberately avoided reintroducing a daemon/process boundary while the runtime-snapshot architecture was being stabilized. That was the right constraint during the initial simplification phase.

After the pre-migration design pass and the RW-103 through RW-106 groundwork, we now have:

1. A checked-in Claude hook capability contract.
2. An observation and projection scaffold.
3. A host-agnostic runtime boundary prototype.
4. Replay and shadow parity gates wired into operational verification.

At this point, the remaining question is no longer whether a process boundary is technically possible. It is whether we want to settle the runtime ownership boundary before further feature expansion.

## Decision

Adopt a dedicated local runtime service as the target architecture.

Specifically:

1. The runtime service is the application boundary for tracking.
2. The Swift app becomes a client of the runtime service.
3. Claude ingress adapters and shell signal adapters target the runtime service.
4. Observation journal plus derived read models remain the target runtime model.
5. The existing in-process/snapshot path becomes migration scaffolding, not the long-term design.

## Consequences

Positive:

1. Runtime continuity is no longer tied to the visible app lifecycle.
2. The ownership boundary becomes explicit and easier to preserve as new features are added.
3. Future integrations have one stable local runtime boundary to target.
4. UI feature work is less likely to entangle itself with runtime-host concerns.

Tradeoffs:

1. We reintroduce process lifecycle management and local transport complexity.
2. Migration requires careful cutover to avoid recreating daemon-era ambiguity.
3. The service boundary must remain narrow and local, or we risk architectural backsliding.

## Guardrails

1. The runtime service must remain local-only and authenticated.
2. Adapters remain forwarders, not reducers.
3. Replay and shadow parity stay green before any cutover.
4. The process split must be implemented as composition-root work, not by moving domain semantics out of Rust.

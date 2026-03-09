# Architecture Decisions

## Rust Owns Domain Truth

Rust is canonical for runtime state, setup behavior, project and idea persistence, and bounded-context orchestration.

## Swift Owns Delivery And Platform Side Effects

Swift is canonical for UI composition, interaction flow, terminal activation execution, and macOS integrations.

## Rust Uses `contexts/`

Rust bounded contexts live under `core/capacitor-core/src/contexts/`.
`ContextServices` is the internal composition layer behind `CoreRuntime`.

## Swift Uses `AppState` As The Shell Environment Hub

`apps/swift/Sources/Capacitor/Composition/AppState.swift` remains the top-level SwiftUI shell environment object.
It may expose canonical collaborators, but it does not own construction or duplicate policy.

## Governance Lives In `architecture/`

`architecture/` is the permanent architecture-governance surface.
Detailed program history lives under `docs/archive/`.

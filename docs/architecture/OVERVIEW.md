# Architecture Overview

Capacitor is a local-first macOS app with a Rust core and a Swift app shell.

## Rust Core

Location: `core/capacitor-core/`

- domain contracts and snapshot truth
- hook ingest, reduction, query, and storage
- setup, project, and idea services
- bounded contexts under `src/contexts/`

## Swift App

Location: `apps/swift/Sources/Capacitor/`

- `Adapters/`: external integrations and bridge implementations
- `Application/`: app-facing state and use-case orchestration
- `Composition/`: top-level app wiring and shell environment state
- `Support/`: platform support code and infrastructure helpers
- `Views/`: SwiftUI rendering

## Guarded Constraints

- no return to `Features/`
- no return to top-level Swift `Models/*.swift`
- no return to retired directory surfaces

Architecture guard: `scripts/architecture/check_architecture_guards.sh`

# Charter

## Mission

Turn iTerm and Terminal.app into first-class Swift host-terminal adapters with checked focus and launch behavior, while keeping Capacitor's existing activation coordinator and TTY-based routing strategy.

## Scope

- `apps/swift/Sources/Capacitor/Models/TerminalDrivers.swift`
- `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- `apps/swift/Sources/Capacitor/Models/TerminalActivationCoordinator.swift`
- `apps/swift/Sources/Capacitor/Models/GhosttyAutomationClient.swift`
- `apps/swift/Sources/Capacitor/Models/AppState.swift`
- `apps/swift/Sources/Capacitor/Models/SupportedTerminalApp.swift`
- `apps/swift/Sources/Capacitor/Models/ProjectCreationCoordinator.swift`
- `apps/swift/Tests/CapacitorTests`
- `.claude/docs/terminal-activation-ux-spec.md`
- `docs/ARCHITECTURE.md`
- `docs/manual-qa`

## Critical Workflows

- Project-card click focuses an existing iTerm client by tmux client TTY.
- Project-card click focuses an existing Terminal.app client by tmux client TTY.
- No-client activation launches or attaches into the preferred host terminal with the existing tmux attach or create behavior.
- Project creation and resume still emit a valid terminal launch script through `TerminalScripts.launchWithCommand(...)`.
- Activation failures surface terminal-aware copy instead of Ghostty-specific fallback text.
- Ghostty activation behavior stays unchanged.

## External Surfaces

- macOS AppleScript via `osascript`
- `System Events`
- `open -b <bundle-id>`
- tmux CLI attach and switch flows
- App toast copy in SwiftUI
- Manual QA evidence under `docs/manual-qa`

## Invariants

- Rust keeps ownership of runtime routing inputs and route derivation.
- Swift keeps ownership of activation execution.
- `TerminalActivationCoordinator` remains the orchestration boundary.
- iTerm and Terminal.app stay on the TTY-based activation strategy.
- Ghostty stays a special-case adapter and is not flattened into a lowest-common-denominator interface.
- The single-client, session-swapping tmux model remains unchanged.
- Internal Swift breaking changes are allowed if all in-repo callers migrate in the same slice.

## Non-Goals

- Re-opening the broader terminal architecture debate.
- Adding new supported terminals.
- Reworking tmux routing, Rust ownership, or session-swapping policy.
- Introducing a new cross-terminal abstraction layer that forces Ghostty into the host-terminal model.
- Preserving the shared host driver for backwards compatibility after both host adapters ship.

## Guardrails

- Write failing tests for each host adapter behavior before implementation.
- Keep per-app ownership at the `TerminalDriver` layer; shared code may only be pure helper code for escaping, script construction, or result parsing.
- Move `TerminalActivationFailureReason` out of the Ghostty-only file before adding host-terminal failure cases.
- Make host launch execution checked without blocking the main actor; do not reintroduce another fire-and-forget blind spot.
- Delete `ScriptedTerminalDriver` in the same slice that migrates the second host terminal.
- Keep Ghostty behavior and tests green throughout the migration.

## Ship Gate

### Automated Checks

- `bash docs/plans/terminal-host-adapters/guard.sh`
- `bash docs/plans/terminal-routing-foundation/guard.sh`
- `cd apps/swift && swift test --filter 'ITermTerminalDriverTests|TerminalAppTerminalDriverTests|TerminalLauncherTests|GhosttyTerminalDriverTests|AppState.*Tests|ProjectCreationCoordinatorTests'`
- `cd apps/swift && swift test`
- `cargo test -p capacitor-core`

### Manual Checks

- One live iTerm existing-TTY activation proof with the new iTerm-specific driver log label.
- One live Terminal.app existing-TTY activation proof with the new Terminal.app-specific driver log label.
- One live iTerm no-client attach-or-create proof.
- One live Terminal.app no-client attach-or-create proof.

### Cleanliness Checks

- `ScriptedTerminalDriver` is fully removed from source, tests, and active docs.
- No active docs or UI copy still imply non-Ghostty failures are Ghostty failures.
- No host-terminal logic is duplicated between a shared runtime owner and the new concrete drivers.

# Activation Config: Migrate to Rust Core

**Status:** DRAFT
**Created:** 2026-01-25
**Context:** Shell Matrix Panel implementation revealed architectural debt

## Problem

The activation configuration system is currently Swift-only:

```
Swift Client
├── ParentAppType, ShellContext, TerminalMultiplicity (enums)
├── ActivationStrategy (enum)
├── ShellScenario, ScenarioBehavior (structs)
├── ScenarioBehavior.defaultBehavior() (decision logic)
├── ActivationConfigStore (UserDefaults persistence)
└── Strategy execution (AppleScript, NSWorkspace, etc.)
```

If Capacitor grows to support:
- Web dashboard
- CLI tool
- Linux/Windows clients
- Remote session management

...each would need to reimplement the scenario logic and default behaviors.

## Proposed Architecture

**Principle:** Rust owns policy (what to do), clients own mechanism (how to do it).

```
┌─────────────────────────────────────────────────────────┐
│ Rust Core (hud-core)                                    │
│                                                         │
│  core/hud-core/src/activation/                          │
│  ├── mod.rs                                             │
│  ├── types.rs      // ParentAppType, ShellContext, etc. │
│  ├── scenario.rs   // ShellScenario, ScenarioBehavior   │
│  ├── defaults.rs   // default_behavior() logic          │
│  └── config.rs     // JSON persistence                  │
│                                                         │
│  Persists to: ~/.capacitor/activation.json              │
└─────────────────────────────────────────────────────────┘
                           │
                           │ UniFFI bindings
                           ▼
┌─────────────────────────────────────────────────────────┐
│ Swift Client                                            │
│                                                         │
│  Models/                                                │
│  ├── TerminalLauncher.swift   // Strategy execution     │
│  │   └── executeStrategy()    // macOS-specific APIs    │
│  │                                                      │
│  Views/Debug/ShellMatrixPanel/                          │
│  └── UI only, calls Rust for data                       │
└─────────────────────────────────────────────────────────┘
```

## What Moves to Rust

| Component | Current | Proposed |
|-----------|---------|----------|
| `ParentAppType` | `ActivationConfig.swift` | `activation/types.rs` |
| `ParentAppCategory` | `ActivationConfig.swift` | `activation/types.rs` |
| `ShellContext` | `ActivationConfig.swift` | `activation/types.rs` |
| `TerminalMultiplicity` | `ActivationConfig.swift` | `activation/types.rs` |
| `ActivationStrategy` | `ActivationConfig.swift` | `activation/types.rs` |
| `ShellScenario` | `ActivationConfig.swift` | `activation/scenario.rs` |
| `ScenarioBehavior` | `ActivationConfig.swift` | `activation/scenario.rs` |
| `defaultBehavior()` | `ActivationConfig.swift` | `activation/defaults.rs` |
| Config persistence | UserDefaults | `~/.capacitor/activation.json` |

## What Stays in Swift

| Component | Reason |
|-----------|--------|
| `TerminalLauncher.executeStrategy()` | Uses macOS-specific APIs |
| AppleScript queries | macOS-only |
| `NSWorkspace` activation | macOS-only |
| `kitty @` remote control | Could be cross-platform but execution is local |
| IDE CLI invocation | Cross-platform but path resolution is OS-specific |
| Shell Matrix Panel UI | SwiftUI views |

## Rust API Design

```rust
// core/hud-core/src/activation/types.rs

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[derive(uniffi::Enum)]
pub enum ParentAppType {
    Cursor,
    Vscode,
    VscodeInsiders,
    Iterm2,
    Terminal,
    Ghostty,
    Kitty,
    Alacritty,
    Warp,
    Tmux,
    Unknown,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[derive(uniffi::Enum)]
pub enum ActivationStrategy {
    ActivateByTty,
    ActivateByApp,
    ActivateKittyRemote,
    ActivateIdeWindow,
    SwitchTmuxSession,
    ActivateHostFirst,
    LaunchNewTerminal,
    PriorityFallback,
    Skip,
}

// core/hud-core/src/activation/scenario.rs

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[derive(uniffi::Record)]
pub struct ShellScenario {
    pub parent_app: ParentAppType,
    pub context: ShellContext,
    pub multiplicity: TerminalMultiplicity,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[derive(uniffi::Record)]
pub struct ScenarioBehavior {
    pub primary_strategy: ActivationStrategy,
    pub fallback_strategy: Option<ActivationStrategy>,
}

impl ScenarioBehavior {
    pub fn default_for(scenario: &ShellScenario) -> Self {
        // The decision logic currently in Swift
    }
}

// core/hud-core/src/activation/config.rs

#[derive(uniffi::Object)]
pub struct ActivationConfig {
    overrides: HashMap<String, ScenarioBehavior>,
    config_path: PathBuf,
}

#[uniffi::export]
impl ActivationConfig {
    #[uniffi::constructor]
    pub fn new() -> Self { ... }

    pub fn behavior_for(&self, scenario: &ShellScenario) -> ScenarioBehavior { ... }
    pub fn set_behavior(&mut self, scenario: &ShellScenario, behavior: ScenarioBehavior) { ... }
    pub fn reset_behavior(&mut self, scenario: &ShellScenario) { ... }
    pub fn reset_all(&mut self) { ... }
    pub fn is_modified(&self, scenario: &ShellScenario) -> bool { ... }
    pub fn modified_count(&self) -> u32 { ... }
}
```

## Swift Client Changes

```swift
// After migration, TerminalLauncher becomes thinner:

@MainActor
final class TerminalLauncher {
    private let config: ActivationConfig  // From Rust via UniFFI

    func activateExistingTerminal(shell: ShellEntry, ...) {
        let scenario = ShellScenario(
            parentApp: ParentAppType.from(shell.parentApp),
            context: shell.tmuxSession != nil ? .tmux : .direct,
            multiplicity: .init(shellCount: shellCount)
        )

        let behavior = config.behaviorFor(scenario: scenario)

        // Execute using macOS APIs (stays in Swift)
        let success = executeStrategy(behavior.primaryStrategy, ...)
        if !success, let fallback = behavior.fallbackStrategy {
            executeStrategy(fallback, ...)
        }
    }

    // Strategy execution stays in Swift - it's macOS-specific
    private func executeStrategy(_ strategy: ActivationStrategy, ...) -> Bool {
        switch strategy {
        case .activateByTty: return activateByTTY(...)
        case .activateIdeWindow: return activateIDEWindow(...)
        // ...
        }
    }
}
```

## Migration Steps

1. **Create Rust module** (`core/hud-core/src/activation/`)
   - Define all enums and structs
   - Implement `ScenarioBehavior::default_for()`
   - Add JSON persistence to `~/.capacitor/activation.json`

2. **Add UniFFI exports**
   - Export types and `ActivationConfig` object
   - Regenerate Swift bindings

3. **Update Swift client**
   - Delete `ActivationConfig.swift` enums (use Rust-generated ones)
   - Update `TerminalLauncher` to use `ActivationConfig` from Rust
   - Update Shell Matrix Panel to use Rust types

4. **Migrate existing config**
   - On first run, if UserDefaults has data, migrate to JSON file
   - Remove UserDefaults usage

5. **Test thoroughly**
   - Verify all scenarios still work
   - Verify persistence works across restarts
   - Verify panel still functions

## Benefits

- **Single source of truth** for scenario logic
- **Cross-platform ready** when/if other clients emerge
- **Consistent defaults** across all clients
- **Shared persistence format** (JSON, not platform-specific)
- **Testable in Rust** without UI

## Risks / Considerations

- **UniFFI overhead** for frequent calls (mitigated: config is read once, cached)
- **Migration complexity** (one-time cost)
- **Two languages to maintain** (already the case)

## When to Implement

Trigger conditions:
- Building a second client (web dashboard, CLI)
- Major refactor of hud-core anyway
- Performance issues with current approach (unlikely)

Until then, current Swift implementation is acceptable tech debt.

## References

- Current implementation: `apps/swift/Sources/Capacitor/Models/ActivationConfig.swift`
- Strategy execution: `apps/swift/Sources/Capacitor/Models/TerminalLauncher.swift`
- Tuning panel: `apps/swift/Sources/Capacitor/Views/Debug/ShellMatrixPanel/`

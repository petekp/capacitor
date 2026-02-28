# Contributing

## Prerequisites

- Apple Silicon Mac (Intel/Rosetta won't work)
- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- Rust toolchain (setup will install it if you don't have it)

## Getting started

```bash
git clone https://github.com/petekp/capacitor.git
cd capacitor
./scripts/dev/setup.sh
```

This handles the full setup: environment checks, dependencies, building, hooks.

Once that's done:

```bash
./scripts/dev/restart-current.sh
```

This rebuilds everything and launches a debug build using the current runtime context.

## Development workflow

Canonical launchers:

- `./scripts/dev/restart-current.sh`: reuse current channel/profile context
- `./scripts/dev/restart-alpha-stable.sh`: alpha channel + stable profile (daily polish)
- `./scripts/dev/restart-alpha-frontier.sh`: alpha channel + frontier profile (new feature planning)

`restart-app.sh` remains available for explicit control. Useful flags:

- `--swift-only` / `-s`: skip the Rust build when you're only changing Swift
- `--force` / `-f`: force a full rebuild
- `--channel <name>`: set runtime channel (`dev`, `alpha`, `beta`, `prod`)
- `--profile <stable|frontier>`: set runtime feature profile
- `--frontier`: alias for `--profile frontier`

During the public alpha cycle, dev/debug launches are alpha-only by default.  
Runtime context is persisted in `~/.capacitor/runtime-context.env` after each restart.
If you intentionally need non-alpha in debug, use:

```bash
CAPACITOR_ALLOW_NON_ALPHA=1 ./scripts/dev/restart-app.sh --channel prod --profile stable
```

For Rust-only work, cargo works fine:

```bash
cargo build -p capacitor-core --release
cargo build -p hud-hook --release
```

## Testing

```bash
./scripts/dev/run-tests.sh          # everything
./scripts/dev/run-tests.sh --quick  # skip Swift tests
```

Or individually:

```bash
cargo fmt                         # format (required before commits)
cargo clippy -- -D warnings       # lint
cargo test                        # test
```

Pre-commit hooks run `cargo fmt --check` and `cargo test` automatically, so you'll catch issues before pushing.

## Project structure

```
capacitor/
├── core/capacitor-core/  # Canonical runtime domain + reducer + snapshot storage
├── core/capacitor-core/        # Rust business logic, UniFFI bindings
├── core/hud-hook/        # Rust CLI hook handler
├── apps/swift/           # SwiftUI app
└── scripts/              # Dev, CI, and release scripts
```

[CLAUDE.md](CLAUDE.md) covers architecture and common gotchas.

## Submitting changes

1. Open an issue first for anything non-trivial
2. Fork and branch
3. Make sure `cargo fmt`, `cargo clippy -- -D warnings`, and `cargo test` all pass
4. Open a PR against `main`

`cargo fmt` is enforced by pre-commit hooks. Rust builds in release mode; Swift links against the release dylib. `restart-app.sh` regenerates bindings automatically after Rust API changes.

See `.claude/docs/gotchas.md` for things that might trip you up.

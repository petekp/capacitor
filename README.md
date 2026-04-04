![Capacitor banner](assets/banner.png)

# Capacitor

Capacitor is a companion app for [Claude Code](https://claude.ai/claude-code) (more coding agents on the way, starting with Codex). I built it because I was tired of coding agent tools that try to be the terminal, the editor, the git client, and the chat window all at once. None of those things end up as good as the tools you already use.

If you've ever lost track of which terminal window or tmux pane has which session, that's what Capacitor is for. It keeps your sessions visible and one click away. More features are on the way, ones that further streamline your process and respect your tooling preferences.

## Download

**[Download the latest alpha release](https://github.com/petekp/capacitor/releases)** (Apple Silicon, macOS 14+)

Capacitor is in early alpha. Expect rough edges. [Report issues here.](https://github.com/petekp/capacitor/issues)

## Why use it

- Keep project context visible without terminal tab hunting
- See live session state at a glance
- Click a project card to return to the right terminal/tmux context
- Stay focused when juggling multiple projects
- It's _fun_!

## How terminal switching works

When you click a project card, Capacitor tries to get you back to the right terminal/tmux context:

- Prefer the terminal app already hosting the matching live client or shell
- Reuse an attached tmux client when possible
- Switch to the correct tmux session or pane
- Fall back to opening a fresh terminal only when reuse fails

Current terminal support:

- Ghostty 1.3+ with native AppleScript routing
- iTerm via TTY-based tab reuse
- Terminal.app via TTY-based tab reuse

**Known rough edges:** Ghostty routing and launch both depend on Ghostty's native AppleScript support in Ghostty 1.3+. If Ghostty AppleScript is disabled (`macos-applescript = false`) or macOS Automation access is denied, Capacitor will not be able to switch or create Ghostty surfaces natively.

## Install

1. Download the latest DMG from the [Releases page](https://github.com/petekp/capacitor/releases).
2. Drag `Capacitor.app` into `/Applications`.
3. Launch the app.

## Quick Start

1. Open Capacitor.
2. Connect a project (or drag a project folder into the app).
3. Run Claude Code in your terminal(s) as normal.
4. Click project cards in Capacitor to jump to the right session.

## Developing Capacitor

Formal verification is part of the repo's default engineering surface.

Architecture docs for coding agents start at `.claude/docs/architecture-primer.md`.

```bash
./scripts/verify/verify.sh --bootstrap
./scripts/verify/verify.sh --layers 1
./scripts/verify/verify.sh --layers 1 --evolve
```

Verifier specs and policy live under `.verifier/`. Cached facts and reports are generated locally under `.verifier/facts/` and `.verifier/reports/`.

## How it works

Capacitor is a sidecar. It watches what Claude Code is doing without getting in the way.

On first launch, it installs a small hook binary (`~/.local/bin/hud-hook`) and adds entries to Claude Code's `~/.claude/settings.json`. Hook events flow into a local runtime service, which owns live runtime reads and persists runtime artifacts under `~/.capacitor/runtime/` (including `app_snapshot.json`). The Swift app and dev tooling query the runtime service for live state, while the persisted artifact remains a debugging and recovery aid.

It doesn't call the Anthropic API directly. It observes local Claude Code activity and manages its own local runtime state.

## Data & privacy

Capacitor reads from `~/.claude/` (transcripts, settings) and writes its own state to `~/.capacitor/`. It also adds hook entries to `~/.claude/settings.json` but doesn't touch your other settings.

By default, data stays on your machine. If you run `node scripts/transparent-ui-server.mjs`, Capacitor exposes a local debug/telemetry sink on `localhost:9133` for browser inspection and local telemetry capture. That service is optional and not part of the app's live runtime boundary.

Optional remote ingest is supported only when telemetry env vars are configured (for example: `CAPACITOR_FEEDBACK_API_URL` / `CAPACITOR_TELEMETRY_URL` with `CAPACITOR_INGEST_KEY`). In that mode, feedback submissions and a limited allowlist of diagnostic telemetry events can be sent to your configured endpoint.

The "Include anonymized telemetry" toggle in Settings controls whether app metadata gets attached to GitHub issue drafts when you submit feedback. Project paths are redacted by default.

## Permissions

Terminal switching uses AppleScript, so macOS will ask for Automation access the first time you click a project card. If you dismiss the prompt, Capacitor won't be able to control the terminal app you're using. You can re-grant it later in System Settings > Privacy & Security > Automation.

## Settings

`⌘,` opens Settings. Current toggles:

- Floating mode (borderless, position anywhere)
- Always on top
- Ready chime (plays a sound when Claude finishes)
- Automatic update checks
- Feedback privacy (anonymized telemetry for issue drafts, project path inclusion)

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `⌘O` | Connect project |
| `⌘1` | Vertical layout |
| `⌘2` | Dock layout |
| `⌘⇧T` | Toggle floating mode |
| `⌘⇧P` | Toggle always on top |
| `⌘,` | Settings |

## Requirements

- Apple Silicon Mac (`arm64`)
- macOS 14+
- At least one supported terminal: Ghostty 1.3+ with AppleScript enabled, iTerm, or Terminal.app
- Claude Code installed
- `tmux` recommended (Capacitor can restore exact pane context)

## Troubleshooting

**Projects not showing up?** Check the hooks status indicator in the app. If it says something's wrong, click "Fix All."

**Terminal switching broken?** Check Automation access for the terminal app you use in System Settings > Privacy & Security > Automation. If you use Ghostty, also confirm `macos-applescript = true`.

**Runtime issues?** If something seems off, start with the local runtime service health (`./scripts/dev/agent-observe.sh health`). If that command reports degraded artifact mode, treat it as offline/debug context only and inspect `~/.capacitor/runtime/` (for example `app_snapshot.json` and `app-debug.log`) as persisted-state evidence, not live runtime truth.

For coding-agent debugging in this repo, use:

- `./scripts/dev/agent-observe.sh diagnose` (one-shot full diagnostics)
- `.claude/docs/debugging-guide.md` (canonical debugging workflow)

More help: [open a GitHub issue](https://github.com/petekp/capacitor/issues).

## Uninstall

To remove everything:

1. Quit the app
2. `rm -rf /Applications/Capacitor.app`
3. `rm -rf ~/.capacitor`
4. `rm ~/.local/bin/hud-hook`
5. Remove `hud-hook` entries from `~/.claude/settings.json`
6. Optionally: `defaults delete com.capacitor.app`

## License

MIT. See [LICENSE](LICENSE).

## Feedback

Use the in-app feedback form, or open a [GitHub issue](https://github.com/petekp/capacitor/issues).

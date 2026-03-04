# Landing Page Design

## Goal
Drive downloads of Capacitor for Claude Code power users.

## Decisions
- **Stack:** Next.js deployed to Vercel
- **Layout:** Single viewport, everything above the fold
- **Theme:** Dark, matching the app (deep purple-tinted background, vibrant P3 green accent)
- **Typography:** Minimal — logo/header style + one body text size for everything else

## Layout

```
┌──────────────────────────────────────────────┐
│                                              │
│            CAPACITOR (logo wordmark)         │
│                                              │
│  A glanceable companion for Claude Code      │
│                                              │
│  ┌────────────────────────────────────────┐  │
│  │         Demo video (user-recorded)     │  │
│  └────────────────────────────────────────┘  │
│                                              │
│  • Live session status at a glance           │
│  • One click to the right terminal           │
│  • Works with Ghostty, iTerm2, tmux          │
│  • Respects your tools — never replaces them │
│                                              │
│         [ Download for macOS ]               │
│          v0.2.0-alpha · Apple Silicon        │
│                                              │
│  ─────────────────────────────────────────── │
│  GitHub · macOS 14+ · Alpha                  │
└──────────────────────────────────────────────┘
```

## Visual Design

- **Background:** `hsl(260, 4.5%, 11%)` — Capacitor's app background
- **Accent:** P3 green `oklch(0.8647 0.2886 150.35)` — used for CTA button and logo
- **Text:** White at varying opacity (90% primary, 50% secondary)
- **Video:** Centered, rounded corners, subtle border or glow
- **Download button:** P3 green background, dark text, prominent

## Assets Available
- `assets/logo.svg` — wordmark
- `assets/logomark.svg` — circular mark (for favicon)
- `assets/banner.png` — could be used as fallback
- Demo video: user will record and provide an MP4

## Content
- Subtitle: "A glanceable companion for Claude Code"
- 4 feature bullets (single body text size)
- Download link: GitHub releases (latest .dmg)
- Footer: GitHub repo link, "macOS 14+ · Apple Silicon · Alpha"

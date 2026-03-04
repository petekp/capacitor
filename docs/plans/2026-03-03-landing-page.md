# Landing Page Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a single-viewport dark-themed landing page for Capacitor with demo video, feature bullets, and download CTA, deployed to Vercel via Next.js.

**Architecture:** Next.js app in `site/` directory at repo root. Single `page.tsx` with inline styles via CSS modules. Dark theme matching the macOS app. Video placeholder until user records demo. Logo SVGs copied into `site/public/`.

**Tech Stack:** Next.js 15, React 19, TypeScript, CSS Modules, Vercel deployment

---

### Task 1: Scaffold Next.js project

**Files:**
- Create: `site/` (via `npx create-next-app`)

**Step 1: Create the Next.js app**

```bash
cd /Users/petepetrash/Code/capacitor
npx create-next-app@latest site --typescript --app --no-tailwind --no-eslint --no-src-dir --import-alias "@/*"
```

Accept defaults. This creates `site/` with App Router.

**Step 2: Clean scaffolded files**

Delete the default content from `site/app/page.tsx`, `site/app/layout.tsx`, and `site/app/globals.css`. We'll replace them entirely in subsequent tasks.

**Step 3: Copy brand assets**

```bash
cp assets/logo.svg site/public/logo.svg
cp assets/logomark.svg site/public/logomark.svg
```

**Step 4: Verify it runs**

```bash
cd site && npm run dev
```

Expected: Next.js dev server starts on localhost:3000.

**Step 5: Commit**

```bash
git add site/
git commit -m "chore(site): scaffold Next.js landing page project"
```

---

### Task 2: Global styles and layout

**Files:**
- Modify: `site/app/globals.css`
- Modify: `site/app/layout.tsx`

**Step 1: Write global styles**

`site/app/globals.css`:
```css
*,
*::before,
*::after {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --bg: hsl(260, 4.5%, 11%);
  --surface: hsl(260, 5.5%, 14.5%);
  --text-primary: rgba(255, 255, 255, 0.9);
  --text-secondary: rgba(255, 255, 255, 0.5);
  --accent: oklch(0.8647 0.2886 150.35);
  --accent-fallback: rgb(77, 254, 115);
  --radius: 12px;
}

html, body {
  height: 100%;
  background: var(--bg);
  color: var(--text-primary);
  font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
  -webkit-font-smoothing: antialiased;
}
```

**Step 2: Write layout**

`site/app/layout.tsx`:
```tsx
import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Capacitor — A glanceable companion for Claude Code",
  description:
    "Live session status, one-click terminal focus, and respect for your existing tools. A macOS companion for Claude Code power users.",
  openGraph: {
    title: "Capacitor",
    description: "A glanceable companion for Claude Code",
    type: "website",
  },
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
```

**Step 3: Verify**

```bash
cd site && npm run dev
```

Expected: Dark background, no default Next.js content.

**Step 4: Commit**

```bash
git add site/app/globals.css site/app/layout.tsx
git commit -m "feat(site): add dark theme global styles and layout"
```

---

### Task 3: Build the page

**Files:**
- Create: `site/app/page.module.css`
- Modify: `site/app/page.tsx`

**Step 1: Write page styles**

`site/app/page.module.css`:
```css
.page {
  display: flex;
  flex-direction: column;
  align-items: center;
  justify-content: center;
  min-height: 100vh;
  padding: 3rem 2rem;
  gap: 2rem;
  max-width: 720px;
  margin: 0 auto;
}

.logo {
  width: 280px;
  height: auto;
}

.subtitle {
  color: var(--text-secondary);
  font-size: 1rem;
  text-align: center;
}

.video {
  width: 100%;
  border-radius: var(--radius);
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: var(--surface);
  aspect-ratio: 16 / 10;
  object-fit: cover;
}

.videoPlaceholder {
  width: 100%;
  border-radius: var(--radius);
  border: 1px solid rgba(255, 255, 255, 0.08);
  background: var(--surface);
  aspect-ratio: 16 / 10;
  display: flex;
  align-items: center;
  justify-content: center;
  color: var(--text-secondary);
  font-size: 1rem;
}

.features {
  list-style: none;
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  font-size: 1rem;
  color: var(--text-primary);
}

.features li::before {
  content: "·";
  margin-right: 0.75rem;
  color: var(--text-secondary);
}

.download {
  display: inline-flex;
  align-items: center;
  gap: 0.5rem;
  padding: 0.75rem 2rem;
  background: var(--accent, var(--accent-fallback));
  color: hsl(260, 4.5%, 11%);
  font-size: 1rem;
  font-weight: 600;
  border: none;
  border-radius: var(--radius);
  text-decoration: none;
  cursor: pointer;
  transition: opacity 0.15s;
}

.download:hover {
  opacity: 0.9;
}

.meta {
  font-size: 1rem;
  color: var(--text-secondary);
  text-align: center;
}

.footer {
  font-size: 1rem;
  color: var(--text-secondary);
  display: flex;
  gap: 1rem;
  align-items: center;
}

.footer a {
  color: var(--text-secondary);
  text-decoration: underline;
  text-underline-offset: 2px;
}

.footer a:hover {
  color: var(--text-primary);
}

.divider {
  width: 100%;
  height: 1px;
  background: rgba(255, 255, 255, 0.06);
}
```

**Step 2: Write page component**

`site/app/page.tsx`:
```tsx
import styles from "./page.module.css";
import Image from "next/image";

const DOWNLOAD_URL =
  "https://github.com/nicepete/capacitor/releases/latest";

export default function Home() {
  return (
    <main className={styles.page}>
      <Image
        src="/logo.svg"
        alt="Capacitor"
        width={280}
        height={31}
        className={styles.logo}
        priority
      />

      <p className={styles.subtitle}>
        A glanceable companion for Claude Code
      </p>

      {/* Replace with <video> once demo is recorded */}
      <div className={styles.videoPlaceholder}>
        Demo video coming soon
      </div>

      <ul className={styles.features}>
        <li>Live session status at a glance</li>
        <li>One click to the right terminal</li>
        <li>Works with Ghostty, iTerm2, tmux</li>
        <li>Respects your tools — never replaces them</li>
      </ul>

      <a href={DOWNLOAD_URL} className={styles.download}>
        Download for macOS
      </a>

      <p className={styles.meta}>
        v0.2.0-alpha · Apple Silicon
      </p>

      <div className={styles.divider} />

      <footer className={styles.footer}>
        <a href="https://github.com/nicepete/capacitor">GitHub</a>
        <span>macOS 14+</span>
        <span>Alpha</span>
      </footer>
    </main>
  );
}
```

> **Note:** The logo SVG has `fill="black"` — it needs to be white on a dark background. Either modify the SVG file to `fill="white"` or apply a CSS filter: `.logo { filter: invert(1); }`. The CSS filter approach avoids modifying the source asset.

**Step 3: Fix logo color for dark theme**

Add to `page.module.css` under `.logo`:
```css
.logo {
  /* existing styles */
  filter: invert(1);
}
```

**Step 4: Verify locally**

```bash
cd site && npm run dev
```

Expected: Dark page with logo (white), subtitle, video placeholder, 4 bullets, green download button, version text, footer. All above the fold on a standard display.

**Step 5: Commit**

```bash
git add site/app/page.tsx site/app/page.module.css
git commit -m "feat(site): build single-viewport landing page"
```

---

### Task 4: Favicon from logomark

**Files:**
- Modify: `site/app/layout.tsx` (add icon metadata)
- Create: `site/app/icon.svg`

**Step 1: Create favicon**

Copy `site/public/logomark.svg` to `site/app/icon.svg` and change `fill="black"` to `fill="white"` so it's visible on dark browser tabs.

**Step 2: Verify**

Browser tab should show the Capacitor logomark.

**Step 3: Commit**

```bash
git add site/app/icon.svg
git commit -m "feat(site): add logomark favicon"
```

---

### Task 5: Build check and deploy prep

**Files:**
- None new

**Step 1: Run production build**

```bash
cd site && npm run build
```

Expected: Build succeeds with no errors.

**Step 2: Verify static export works**

```bash
cd site && npm start
```

Visit localhost:3000, verify page renders correctly.

**Step 3: Commit any remaining changes**

```bash
git add -A site/
git commit -m "chore(site): verify production build"
```

---

### Task 6: Deploy to Vercel

**Step 1: Deploy**

```bash
cd site && npx vercel --yes
```

Or if Vercel CLI is already set up:
```bash
cd site && vercel
```

Set root directory to `site` if prompted.

**Step 2: Verify deployment**

Visit the Vercel URL and confirm the page loads correctly.

**Step 3: Commit Vercel config if generated**

```bash
git add site/.vercel/ site/vercel.json 2>/dev/null
git commit -m "chore(site): add Vercel deployment config"
```

---

### Post-Implementation: Video Integration

When the user records a demo video:

1. Save as `site/public/demo.mp4`
2. In `page.tsx`, replace the `videoPlaceholder` div with:

```tsx
<video
  className={styles.video}
  autoPlay
  loop
  muted
  playsInline
>
  <source src="/demo.mp4" type="video/mp4" />
</video>
```

3. Remove the `.videoPlaceholder` CSS class.

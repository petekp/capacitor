import styles from "./page.module.css";
import LogomarkAnimated from "./LogomarkAnimated";
import EnergyRipples from "./EnergyRipples";
import GlassTextHeading from "./GlassTextHeading";
import FeatureGlow from "./FeatureGlow";

const DOWNLOAD_URL =
  "https://github.com/petekp/capacitor/releases/latest";
const GITHUB_URL = "https://github.com/petekp/capacitor";

export default function Home() {
  return (
    <>
      <EnergyRipples anchorId="logomark-anchor" />
      <header className={`${styles.header} glass glass-strength-10 glass-surface`}>
        <div className={styles.headerInner}>
          <img
            src="/logo-small.svg"
            alt="Capacitor"
            className={styles.headerLogo}
          />
          <nav className={styles.headerNav}>
            <a href={GITHUB_URL} className={styles.headerLink} aria-label="GitHub">
              <svg width="20" height="20" viewBox="0 0 16 16" fill="currentColor">
                <path d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"/>
              </svg>
            </a>
            <a href={DOWNLOAD_URL} className={styles.headerDownload}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
              Download for macOS
            </a>
          </nav>
        </div>
      </header>

      <main className={styles.page}>
        <div className={styles.hero}>
          <div className={styles.heroText}>
            <h1 className={styles.heading}>
              <GlassTextHeading>
                The missing link between you and Claude Code
              </GlassTextHeading>
            </h1>
            <p className={styles.subtitle}>
              A bring-your-own-terminal, always visible, multi-session orchestrator for Claude Code
            </p>
          </div>
          <div className={styles.heroMarkContainer} id="logomark-anchor">
            <LogomarkAnimated className={styles.heroMark} />
          </div>
        </div>
      <video
        className={styles.video}
        autoPlay
        loop
        muted
        playsInline
      >
        <source src="/capacitor-full-1080.webm" type="video/webm" />
        <source src="/capacitor-full-1080.mp4" type="video/mp4" />
      </video>

      <p className={styles.callout}>
        If you&rsquo;ve ever lost track of which terminal window or tmux pane
        has which session, that&rsquo;s what Capacitor is for. It keeps your
        sessions visible and one click away.
      </p>

      <FeatureGlow targetId="feature-grid" />
      <div className={styles.featureGrid} id="feature-grid">
        {/* Row 1: full width hero */}
        <div className={`${styles.featureTile} ${styles.tileStatus}`}>
          <span className={styles.specularBloom} />
          <span className={styles.specularBorder} />
          <strong>Live session status</strong>
          <span>
            Keep project context visible without terminal tab hunting. See
            whether each agent is working, ready, waiting, compacting, or
            idle — with color-coded indicators and flash animations on state
            changes.
          </span>
        </div>

        {/* Row 2 */}
        <div className={`${styles.featureTile} ${styles.tileTerminal}`}>
          <span className={styles.specularBloom} />
          <span className={styles.specularBorder} />
          <strong>Bring your own terminal</strong>
          <span>
            Click a project card to return to the right terminal and tmux
            context. Capacitor finds or creates the matching session, switches
            to it, and focuses the window. Works with Ghostty, iTerm2, and
            Terminal.app out of the box.
          </span>
        </div>

        {/* Row 2: narrow right */}
        <div className={`${styles.featureTile} ${styles.tileUpcoming}`}>
          <span className={styles.specularBloom} />
          <span className={styles.specularBorder} />
          <span className={styles.comingSoon}>Coming soon</span>
          <strong>Idea queuing</strong>
          <span>
            Jot down ideas and tasks per-project without leaving your flow.
          </span>
        </div>

        {/* Row 3: narrow left, wide right (zigzag) */}
        <div className={`${styles.featureTile} ${styles.tileUpcoming}`}>
          <span className={styles.specularBloom} />
          <span className={styles.specularBorder} />
          <span className={styles.comingSoon}>Coming soon</span>
          <strong>Automatic git management</strong>
          <span>
            Branching, commits, and worktree lifecycle — handled for you.
          </span>
        </div>
        <div className={`${styles.featureTile} ${styles.tileUpcoming}`}>
          <span className={styles.specularBloom} />
          <span className={styles.specularBorder} />
          <span className={styles.comingSoon}>Coming soon</span>
          <strong>Proactive iteration with milestones</strong>
          <span>
            Your ideas are automatically prioritized, spec&rsquo;ed, and
            presented for approval. Rich artifacts at each milestone. Learns
            your preferences and tastes over time.
          </span>
        </div>
      </div>

      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>Get started</h2>
        <ol className={styles.steps}>
          <li>
            <strong>Download and install</strong>
            <span>
              Grab the DMG from GitHub Releases, drag Capacitor to your
              Applications folder, and launch it.
            </span>
          </li>
          <li>
            <strong>Follow the guided setup</strong>
            <span>
              Capacitor checks that Claude Code is installed, sets up its hooks
              automatically, and offers optional shell integration.
            </span>
          </li>
          <li>
            <strong>Grant Automation access</strong>
            <span>
              The first time you click a project card, macOS will ask for
              permission to control your terminal app. After that, one-click
              switching just works.
            </span>
          </li>
        </ol>
      </section>

      <a href={DOWNLOAD_URL} className={styles.download}>
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg>
        Download for macOS
      </a>

      <p className={styles.requirements}>
        Requires macOS 14+, Apple Silicon, and{" "}
        <a href="https://claude.ai/download">Claude Code</a> installed. tmux strongly recommended.
      </p>

      <a href="/guide" className={styles.guideLink}>
        Read the Literate Guide
      </a>

      <div className={styles.divider} />

      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>Privacy</h2>
        <p className={styles.privacyText}>
          Capacitor is a sidecar. It watches what Claude Code is doing without
          getting in the way. It doesn&rsquo;t call the Anthropic API
          directly — it observes local Claude Code activity and manages its own
          local runtime state. No data leaves your machine. No API keys
          required. No accounts.
        </p>
      </section>

      <section className={styles.section}>
        <h2 className={styles.sectionTitle}>Open source</h2>
        <p className={styles.privacyText}>
          Capacitor is MIT-licensed and developed in the open.{" "}
          <a href={GITHUB_URL} className={styles.inlineLink}>
            Browse the source
          </a>
          , report issues, or contribute on GitHub.
        </p>
      </section>

      <p className={styles.meta}>v0.2.0-alpha · Apple Silicon</p>

      <div className={styles.divider} />

      <footer className={styles.footer}>
        <a href={GITHUB_URL}>GitHub</a>
        <a href="/guide">Guide</a>
        <span>macOS 14+</span>
        <span>MIT License</span>
        </footer>
      </main>
    </>
  );
}

import styles from "./page.module.css";
import Image from "next/image";

const DOWNLOAD_URL =
  "https://github.com/petekp/capacitor/releases/latest";

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
      <div className={styles.videoPlaceholder}>Demo video coming soon</div>

      <ul className={styles.features}>
        <li>Live session status at a glance</li>
        <li>One click to the right terminal</li>
        <li>Works with Ghostty, iTerm2, tmux</li>
        <li>Respects your tools — never replaces them</li>
      </ul>

      <a href={DOWNLOAD_URL} className={styles.download}>
        Download for macOS
      </a>

      <a href="/guide" className={styles.guideLink}>
        Read the Literate Guide
      </a>

      <p className={styles.meta}>v0.2.0-alpha · Apple Silicon</p>

      <div className={styles.divider} />

      <footer className={styles.footer}>
        <a href="https://github.com/petekp/capacitor">GitHub</a>
        <a href="/guide">Guide</a>
        <span>macOS 14+</span>
        <span>Alpha</span>
      </footer>
    </main>
  );
}

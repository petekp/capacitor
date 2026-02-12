#!/usr/bin/env npx tsx
import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";

const DOCS_DIR = join(process.cwd(), "docs/claude-code");

const OFFICIAL_GITHUB_RAW =
  "https://raw.githubusercontent.com/anthropics/claude-code/main";

const MIRROR_GITHUB_RAW =
  "https://raw.githubusercontent.com/ericbuess/claude-code-docs/main/docs";

const OFFICIAL_DOCS = [
  { path: "README.md", output: "github-readme.md" },
  { path: "CHANGELOG.md", output: "github-changelog.md" },
  { path: "plugins/README.md", output: "github-plugins-readme.md" },
];

const MIRROR_DOCS = [
  "amazon-bedrock",
  "analytics",
  "changelog",
  "checkpointing",
  "chrome",
  "claude-code-on-the-web",
  "cli-reference",
  "common-workflows",
  "costs",
  "data-usage",
  "desktop",
  "devcontainer",
  "discover-plugins",
  "github-actions",
  "gitlab-ci-cd",
  "google-vertex-ai",
  "headless",
  "hooks-guide",
  "hooks",
  "iam",
  "interactive-mode",
  "jetbrains",
  "legal-and-compliance",
  "llm-gateway",
  "mcp",
  "memory",
  "microsoft-foundry",
  "model-config",
  "monitoring-usage",
  "network-config",
  "output-styles",
  "overview",
  "plugin-marketplaces",
  "plugins-reference",
  "plugins",
  "quickstart",
  "sandboxing",
  "security",
  "settings",
  "setup",
  "skills",
  "slack",
  "slash-commands",
  "statusline",
  "sub-agents",
  "terminal-config",
  "third-party-integrations",
  "troubleshooting",
  "vs-code",
];

async function fetchWithRetry(
  url: string,
  retries = 3
): Promise<string | null> {
  for (let i = 0; i < retries; i++) {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        console.warn(`  HTTP ${response.status} for ${url}`);
        return null;
      }
      return await response.text();
    } catch (err) {
      console.warn(`  Attempt ${i + 1} failed for ${url}:`, err);
      if (i < retries - 1) await sleep(1000 * (i + 1));
    }
  }
  return null;
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchOfficialGitHubDocs(): Promise<void> {
  console.log("\nFetching official GitHub documentation...");

  for (const doc of OFFICIAL_DOCS) {
    const url = `${OFFICIAL_GITHUB_RAW}/${doc.path}`;
    console.log(`  Fetching ${doc.path}...`);

    const content = await fetchWithRetry(url);
    if (content) {
      const outputPath = join(DOCS_DIR, doc.output);
      writeFileSync(outputPath, content);
      console.log(`  Saved ${doc.output}`);
    } else {
      console.warn(`  Failed to fetch ${doc.path}`);
    }

    await sleep(100);
  }
}

async function fetchMirroredDocs(): Promise<void> {
  console.log("\nFetching mirrored documentation (ericbuess/claude-code-docs)...");

  for (const page of MIRROR_DOCS) {
    const url = `${MIRROR_GITHUB_RAW}/${page}.md`;
    console.log(`  Fetching ${page}.md...`);

    const content = await fetchWithRetry(url);
    if (content) {
      const outputPath = join(DOCS_DIR, `${page}.md`);
      writeFileSync(outputPath, content);
      console.log(`  Saved ${page}.md`);
    } else {
      console.warn(`  Failed to fetch ${page}.md`);
    }

    await sleep(100);
  }
}

async function main(): Promise<void> {
  console.log("Claude Code Documentation Fetcher");
  console.log("==================================");
  console.log(`Output directory: ${DOCS_DIR}`);
  console.log("");
  console.log("Sources:");
  console.log("  - Official: github.com/anthropics/claude-code");
  console.log("  - Mirror:   github.com/ericbuess/claude-code-docs (updated every 3h)");

  if (!existsSync(DOCS_DIR)) {
    mkdirSync(DOCS_DIR, { recursive: true });
  }

  await fetchOfficialGitHubDocs();
  await fetchMirroredDocs();

  console.log("\nDone!");
  console.log(`Documentation saved to ${DOCS_DIR}`);
}

main().catch(console.error);

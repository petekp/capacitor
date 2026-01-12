#!/usr/bin/env npx tsx
/**
 * Agent SDK Documentation Fetcher
 *
 * Fetches documentation from platform.claude.com/docs/en/agent-sdk/*
 * using Playwright to handle JavaScript rendering, then saves as markdown files.
 */

import { writeFileSync, mkdirSync, existsSync } from "fs";
import { join } from "path";

const DOCS_DIR = join(process.cwd(), "docs/full-agent-sdk-docs");
const BASE_URL = "https://platform.claude.com/docs/en/agent-sdk";

const SDK_DOCS = [
  "overview",
  "quickstart",
  "sessions",
  "hooks",
  "subagents",
  "mcp",
  "permissions",
  "typescript",
  "python",
  "user-input",
  "skills",
  "slash-commands",
  "modifying-system-prompts",
  "plugins",
  "migration-guide",
  "streaming-vs-single-mode",
  "custom-tools",
];

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main(): Promise<void> {
  console.log("Agent SDK Documentation Fetcher");
  console.log("================================");
  console.log(`Output directory: ${DOCS_DIR}`);
  console.log(`Source: ${BASE_URL}`);
  console.log("");

  const { chromium } = await import("playwright");

  if (!existsSync(DOCS_DIR)) {
    mkdirSync(DOCS_DIR, { recursive: true });
    console.log(`Created directory: ${DOCS_DIR}`);
  }

  console.log("Launching browser...");
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();

  let successCount = 0;
  let failCount = 0;

  for (const page of SDK_DOCS) {
    const url = `${BASE_URL}/${page}`;
    console.log(`\nFetching ${page}...`);

    try {
      const browserPage = await context.newPage();
      await browserPage.goto(url, { waitUntil: "networkidle", timeout: 30000 });
      await sleep(2000);

      // Use innerText which is simpler and avoids transpilation issues
      const content = await browserPage.evaluate(() => {
        const article = document.querySelector("article") || document.querySelector("main") || document.body;
        return article.innerText || "";
      });

      if (content.length > 200) {
        const outputPath = join(DOCS_DIR, `${page}.md`);
        const header = `# ${page.replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase())}\n\nSource: ${url}\n\n---\n\n`;
        writeFileSync(outputPath, header + content);
        console.log(`  ✓ Saved ${page}.md (${content.length} chars)`);
        successCount++;
      } else {
        console.warn(`  ⚠ Content too short for ${page} (${content.length} chars)`);
        failCount++;
      }

      await browserPage.close();
    } catch (err) {
      console.error(`  ✗ Error fetching ${page}:`, err);
      failCount++;
    }

    await sleep(1000);
  }

  await browser.close();

  console.log("\n================================");
  console.log("Summary:");
  console.log(`  Success: ${successCount}/${SDK_DOCS.length}`);
  console.log(`  Failed:  ${failCount}/${SDK_DOCS.length}`);
  console.log(`\nDocumentation saved to ${DOCS_DIR}`);
}

main().catch(console.error);

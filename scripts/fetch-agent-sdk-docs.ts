#!/usr/bin/env npx tsx
/**
 * Agent SDK Documentation Fetcher
 *
 * Fetches documentation from platform.claude.com/docs/en/agent-sdk/*
 * using Playwright to handle JavaScript rendering, then saves as markdown files.
 *
 * Usage:
 *   npx tsx scripts/fetch-agent-sdk-docs.ts
 *
 * Requirements:
 *   npm install playwright (or pnpm add playwright)
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

  // Dynamic import for playwright (may not be installed)
  let chromium: typeof import("playwright").chromium;
  try {
    const playwright = await import("playwright");
    chromium = playwright.chromium;
  } catch {
    console.error("Error: Playwright not installed.");
    console.error("Run: pnpm add -D playwright && npx playwright install chromium");
    process.exit(1);
  }

  if (!existsSync(DOCS_DIR)) {
    mkdirSync(DOCS_DIR, { recursive: true });
    console.log(`Created directory: ${DOCS_DIR}`);
  }

  console.log("Launching browser...");
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    userAgent:
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
  });

  let successCount = 0;
  let failCount = 0;

  for (const page of SDK_DOCS) {
    const url = `${BASE_URL}/${page}`;
    console.log(`\nFetching ${page}...`);

    try {
      const browserPage = await context.newPage();

      // Navigate and wait for content to load
      await browserPage.goto(url, { waitUntil: "networkidle", timeout: 30000 });

      // Wait for the main content to render
      await browserPage.waitForSelector("article, main, [role='main']", {
        timeout: 10000,
      }).catch(() => {
        // Content selector may vary, continue anyway
      });

      // Additional wait for dynamic content
      await sleep(2000);

      // Extract the markdown content from the rendered page
      const content = await browserPage.evaluate(() => {
        // Find the main documentation content
        const selectors = [
          "article",
          "main article",
          '[role="main"]',
          ".prose",
          ".markdown-body",
          "#content",
          "main",
        ];

        let container: Element | null = null;
        for (const selector of selectors) {
          container = document.querySelector(selector);
          if (container && container.textContent && container.textContent.trim().length > 200) {
            break;
          }
        }

        if (!container) {
          container = document.body;
        }

        // Clone to avoid modifying the page
        const clone = container.cloneNode(true) as HTMLElement;

        // Remove navigation, sidebars, and other non-content elements
        const removeSelectors = [
          "nav",
          "header:not(article header)",
          "footer",
          "aside",
          '[role="navigation"]',
          ".sidebar",
          ".nav",
          ".toc",
          ".table-of-contents",
          "script",
          "style",
          "noscript",
          '[aria-hidden="true"]',
        ];

        removeSelectors.forEach((sel) => {
          clone.querySelectorAll(sel).forEach((el) => el.remove());
        });

        // Convert HTML to markdown-style text
        function htmlToMarkdown(element: Element): string {
          let result = "";

          for (const node of Array.from(element.childNodes)) {
            if (node.nodeType === Node.TEXT_NODE) {
              result += node.textContent || "";
            } else if (node.nodeType === Node.ELEMENT_NODE) {
              const el = node as HTMLElement;
              const tagName = el.tagName.toLowerCase();

              switch (tagName) {
                case "h1":
                  result += `\n# ${el.textContent?.trim()}\n\n`;
                  break;
                case "h2":
                  result += `\n## ${el.textContent?.trim()}\n\n`;
                  break;
                case "h3":
                  result += `\n### ${el.textContent?.trim()}\n\n`;
                  break;
                case "h4":
                  result += `\n#### ${el.textContent?.trim()}\n\n`;
                  break;
                case "h5":
                  result += `\n##### ${el.textContent?.trim()}\n\n`;
                  break;
                case "p":
                  result += `${htmlToMarkdown(el).trim()}\n\n`;
                  break;
                case "pre":
                  const code = el.querySelector("code");
                  const lang = code?.className?.match(/language-(\w+)/)?.[1] || "";
                  result += `\n\`\`\`${lang}\n${el.textContent?.trim()}\n\`\`\`\n\n`;
                  break;
                case "code":
                  if (el.parentElement?.tagName.toLowerCase() !== "pre") {
                    result += `\`${el.textContent}\``;
                  }
                  break;
                case "strong":
                case "b":
                  result += `**${el.textContent}**`;
                  break;
                case "em":
                case "i":
                  result += `*${el.textContent}*`;
                  break;
                case "a":
                  const href = el.getAttribute("href") || "";
                  result += `[${el.textContent}](${href})`;
                  break;
                case "ul":
                case "ol":
                  result += "\n";
                  el.querySelectorAll(":scope > li").forEach((li, i) => {
                    const prefix = tagName === "ol" ? `${i + 1}. ` : "- ";
                    result += `${prefix}${li.textContent?.trim()}\n`;
                  });
                  result += "\n";
                  break;
                case "li":
                  // Handled by ul/ol
                  break;
                case "br":
                  result += "\n";
                  break;
                case "hr":
                  result += "\n---\n\n";
                  break;
                case "table":
                  // Simple table extraction
                  const rows = el.querySelectorAll("tr");
                  rows.forEach((row, rowIdx) => {
                    const cells = row.querySelectorAll("th, td");
                    const cellTexts = Array.from(cells).map((c) => c.textContent?.trim() || "");
                    result += `| ${cellTexts.join(" | ")} |\n`;
                    if (rowIdx === 0) {
                      result += `| ${cellTexts.map(() => "---").join(" | ")} |\n`;
                    }
                  });
                  result += "\n";
                  break;
                case "blockquote":
                  const lines = el.textContent?.trim().split("\n") || [];
                  result += lines.map((l) => `> ${l}`).join("\n") + "\n\n";
                  break;
                case "div":
                case "section":
                case "article":
                case "span":
                  result += htmlToMarkdown(el);
                  break;
                default:
                  result += htmlToMarkdown(el);
              }
            }
          }

          return result;
        }

        return htmlToMarkdown(clone);
      });

      // Clean up the content
      const cleanContent = content
        .replace(/\n{3,}/g, "\n\n")
        .replace(/^\s+/gm, "")
        .trim();

      if (cleanContent.length > 200) {
        const outputPath = join(DOCS_DIR, `${page}.md`);
        const header = `# ${page.replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase())}\n\nSource: ${url}\n\n---\n\n`;
        writeFileSync(outputPath, header + cleanContent);
        console.log(`  ✓ Saved ${page}.md (${cleanContent.length} chars)`);
        successCount++;
      } else {
        console.warn(`  ⚠ Content too short for ${page} (${cleanContent.length} chars)`);
        failCount++;
      }

      await browserPage.close();
    } catch (err) {
      console.error(`  ✗ Error fetching ${page}:`, err);
      failCount++;
    }

    // Be nice to the server
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

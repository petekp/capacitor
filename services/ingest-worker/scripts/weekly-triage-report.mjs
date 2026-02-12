#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

function parseArgs(argv) {
  const args = {
    db: "capacitor-alpha",
    out: null,
    local: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (token === "--db" && argv[i + 1]) {
      args.db = argv[i + 1];
      i += 1;
      continue;
    }
    if (token === "--out" && argv[i + 1]) {
      args.out = argv[i + 1];
      i += 1;
      continue;
    }
    if (token === "--local") {
      args.local = true;
    }
  }

  return args;
}

function extractRows(payload) {
  if (Array.isArray(payload)) {
    const firstWithRows = payload.find((entry) => Array.isArray(entry?.results));
    if (firstWithRows) return firstWithRows.results;
  }

  if (Array.isArray(payload?.result)) {
    const firstWithRows = payload.result.find((entry) => Array.isArray(entry?.results));
    if (firstWithRows) return firstWithRows.results;
  }

  return [];
}

function runD1Query({ db, sql, local }) {
  const args = ["wrangler", "d1", "execute", db, "--json", "--command", sql];
  if (local) {
    args.push("--local");
  } else {
    args.push("--remote");
  }

  const raw = execFileSync("npx", args, { encoding: "utf8" });
  const parsed = JSON.parse(raw);
  return extractRows(parsed);
}

function intValue(value) {
  const asNumber = Number(value ?? 0);
  return Number.isFinite(asNumber) ? asNumber : 0;
}

function boolLabel(value) {
  return intValue(value) === 1 ? "yes" : "no";
}

function buildReport({ summary, feedbackRows, telemetryRows, deliveryRows, db, local }) {
  const generatedAt = new Date().toISOString();

  const summaryRow = summary[0] || {};
  const feedbackCount = intValue(summaryRow.feedback_count);
  const withPaths = intValue(summaryRow.feedback_with_project_paths);

  const lines = [
    "# Capacitor Alpha Weekly Triage Report",
    "",
    `- Generated at: ${generatedAt}`,
    `- Database: ${db} (${local ? "local" : "remote"})`,
    "- Window: last 7 days",
    "",
    "## Summary",
    `- Feedback submissions: ${feedbackCount}`,
    `- Feedback with project paths enabled: ${withPaths}`,
    `- First feedback timestamp: ${summaryRow.first_feedback_at || "n/a"}`,
    `- Last feedback timestamp: ${summaryRow.last_feedback_at || "n/a"}`,
    "",
    "## Latest Feedback",
  ];

  if (feedbackRows.length === 0) {
    lines.push("- No feedback submissions in the last 7 days.");
  } else {
    for (const row of feedbackRows) {
      lines.push(
        `- ${row.submitted_at} | ${row.feedback_id} | channel=${row.channel || "n/a"} | project_paths=${boolLabel(row.include_project_paths)} | ${row.feedback_preview}`,
      );
    }
  }

  lines.push("", "## Top Telemetry Events");
  if (telemetryRows.length === 0) {
    lines.push("- No telemetry events in the last 7 days.");
  } else {
    for (const row of telemetryRows) {
      lines.push(`- ${row.event_type}: ${intValue(row.event_count)}`);
    }
  }

  lines.push("", "## Feedback Delivery Outcomes");
  if (deliveryRows.length === 0) {
    lines.push("- No `quick_feedback_submitted` telemetry events found.");
  } else {
    for (const row of deliveryRows) {
      lines.push(
        `- ${row.occurred_at} | ${row.feedback_id || "(missing)"} | issue_opened=${boolLabel(row.issue_opened)} | endpoint_attempted=${boolLabel(row.endpoint_attempted)} | endpoint_succeeded=${boolLabel(row.endpoint_succeeded)}`,
      );
    }
  }

  return `${lines.join("\n")}\n`;
}

function main() {
  const args = parseArgs(process.argv.slice(2));

  const summary = runD1Query({
    db: args.db,
    local: args.local,
    sql: `
      SELECT
        COUNT(*) AS feedback_count,
        SUM(CASE WHEN include_project_paths = 1 THEN 1 ELSE 0 END) AS feedback_with_project_paths,
        MIN(submitted_at) AS first_feedback_at,
        MAX(submitted_at) AS last_feedback_at
      FROM feedback_submissions
      WHERE datetime(submitted_at) >= datetime('now', '-7 days')
    `,
  });

  const feedbackRows = runD1Query({
    db: args.db,
    local: args.local,
    sql: `
      SELECT
        feedback_id,
        submitted_at,
        channel,
        include_project_paths,
        SUBSTR(REPLACE(feedback_text, '\\n', ' '), 1, 140) AS feedback_preview
      FROM feedback_submissions
      WHERE datetime(submitted_at) >= datetime('now', '-7 days')
      ORDER BY datetime(submitted_at) DESC
      LIMIT 50
    `,
  });

  const telemetryRows = runD1Query({
    db: args.db,
    local: args.local,
    sql: `
      SELECT
        event_type,
        COUNT(*) AS event_count
      FROM telemetry_events
      WHERE datetime(occurred_at) >= datetime('now', '-7 days')
      GROUP BY event_type
      ORDER BY event_count DESC, event_type ASC
      LIMIT 20
    `,
  });

  const deliveryRows = runD1Query({
    db: args.db,
    local: args.local,
    sql: `
      SELECT
        feedback_id,
        occurred_at,
        CAST(json_extract(payload_json, '$.issue_opened') AS INTEGER) AS issue_opened,
        CAST(json_extract(payload_json, '$.endpoint_attempted') AS INTEGER) AS endpoint_attempted,
        CAST(json_extract(payload_json, '$.endpoint_succeeded') AS INTEGER) AS endpoint_succeeded
      FROM telemetry_events
      WHERE event_type = 'quick_feedback_submitted'
        AND datetime(occurred_at) >= datetime('now', '-7 days')
      ORDER BY datetime(occurred_at) DESC
      LIMIT 100
    `,
  });

  const report = buildReport({
    summary,
    feedbackRows,
    telemetryRows,
    deliveryRows,
    db: args.db,
    local: args.local,
  });

  if (args.out) {
    const absoluteOutput = resolve(args.out);
    mkdirSync(dirname(absoluteOutput), { recursive: true });
    writeFileSync(absoluteOutput, report, "utf8");
    process.stdout.write(`Wrote report: ${absoluteOutput}\n`);
    return;
  }

  process.stdout.write(report);
}

try {
  main();
} catch (error) {
  process.stderr.write(`weekly-triage-report failed: ${error}\n`);
  process.exit(1);
}

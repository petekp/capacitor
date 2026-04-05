import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.js";

function makeEnv() {
  const state = {
    insertCalls: 0,
    lastBindValues: null,
    feedbackInsertCalls: 0,
    feedbackBindValues: null,
    feedbackInsertSql: null,
    telemetryInsertSql: null,
    events: [],
    cleanupStatements: [],
  };

  const env = {
    INGEST_KEY: "secret",
    DB: {
      prepare(sql) {
        const normalized = sql.toLowerCase();
        return {
          async run() {
            if (normalized.includes("delete from telemetry_events")) {
              state.cleanupStatements.push(sql);
            }
            return { meta: { last_row_id: 42, changes: 0 }, results: [] };
          },
          bind(...values) {
            state.lastBindValues = values;
            return {
              async run() {
                if (
                  normalized.includes("select 1 as found") &&
                  normalized.includes("from telemetry_events")
                ) {
                  const [eventType, message, feedbackId, sourceIp] = values;
                  const found = state.events.some(
                    (event) =>
                      event.event_type === eventType &&
                      event.message === message &&
                      (event.feedback_id ?? "") === (feedbackId ?? "") &&
                      (event.source_ip ?? "") === (sourceIp ?? ""),
                  );
                  return { results: found ? [{ found: 1 }] : [] };
                }

                if (normalized.includes("insert into feedback_submissions")) {
                  state.feedbackInsertCalls += 1;
                  state.feedbackBindValues = values;
                  state.feedbackInsertSql = sql;
                }

                if (normalized.includes("insert into telemetry_events")) {
                  state.insertCalls += 1;
                  state.telemetryInsertSql = sql;
                  state.events.push({
                    event_type: values[0],
                    message: values[1],
                    feedback_id: values[3] ?? null,
                    source_ip: values[5] ?? null,
                  });
                }

                return { meta: { last_row_id: 42, changes: 1 }, results: [] };
              },
            };
          },
        };
      },
    },
  };

  return { env, state };
}

function telemetryRequest(body) {
  return new Request("https://ingest.example.com/v1/telemetry", {
    method: "POST",
    headers: {
      authorization: "Bearer secret",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

function feedbackRequest(body) {
  return new Request("https://ingest.example.com/v1/feedback", {
    method: "POST",
    headers: {
      authorization: "Bearer secret",
      "content-type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

test("persists runtime feedback snapshot fields", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    feedbackRequest({
      feedback_id: "fb-123",
      submittedAt: "2026-02-16T12:00:00.000Z",
      form: {
        summary: "Runtime feels flaky",
      },
      runtime: {
        enabled: true,
        healthy: false,
        version: "1.2.3",
      },
      daemon: {
        enabled: false,
        healthy: true,
        version: "legacy-daemon",
      },
    }),
    env,
  );

  assert.equal(response.status, 200);
  assert.equal(state.feedbackInsertCalls, 1);
  assert.match(state.feedbackInsertSql ?? "", /runtime_enabled/i);
  assert.doesNotMatch(state.feedbackInsertSql ?? "", /daemon_enabled/i);
  // raw_json should not appear in the INSERT SQL
  assert.doesNotMatch(state.feedbackInsertSql ?? "", /raw_json/i);
  assert.equal(state.feedbackBindValues?.[9], 1);   // runtime_enabled
  assert.equal(state.feedbackBindValues?.[10], 0);   // runtime_healthy
  assert.equal(state.feedbackBindValues?.[11], "1.2.3"); // runtime_version
});

test("feedback INSERT does not include raw_json column", async () => {
  const { env, state } = makeEnv();

  await worker.fetch(
    feedbackRequest({
      feedback_id: "fb-raw-test",
      submittedAt: "2026-02-16T12:00:00.000Z",
      form: { summary: "Testing raw_json removal" },
    }),
    env,
  );

  assert.equal(state.feedbackInsertCalls, 1);
  assert.doesNotMatch(state.feedbackInsertSql ?? "", /raw_json/i);
});

test("drops non-feedback telemetry event types to prevent ingest floods", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "active_project_resolution",
      message: "Resolved active project",
      timestamp: "2026-02-16T12:00:00.000Z",
      payload: {
        active_source: "claude",
      },
    }),
    env,
  );

  assert.equal(response.status, 202);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.dropped, true);
  assert.equal(body.reason, "event_type_not_allowed");
  assert.equal(state.insertCalls, 0);
});

test("persists quick feedback telemetry event types", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "quick_feedback_submit_attempt",
      message: "Quick feedback submit attempted",
      timestamp: "2026-02-16T12:01:00.000Z",
      payload: {
        feedback_id: "fb-123",
      },
    }),
    env,
  );

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.event_id, 42);
  assert.equal(state.insertCalls, 1);
  assert.equal(state.lastBindValues?.[0], "quick_feedback_submit_attempt");
});

test("telemetry INSERT does not include raw_json column", async () => {
  const { env, state } = makeEnv();

  await worker.fetch(
    telemetryRequest({
      type: "quick_feedback_submit_attempt",
      message: "Test",
      timestamp: "2026-02-16T12:01:00.000Z",
      payload: {},
    }),
    env,
  );

  assert.equal(state.insertCalls, 1);
  assert.doesNotMatch(state.telemetryInsertSql ?? "", /raw_json/i);
});

test("persists activation diagnostics telemetry event types", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "activation_outcome",
      message: "are_snapshot_activation",
      timestamp: "2026-02-16T12:03:00.000Z",
      payload: {
        success: true,
      },
    }),
    env,
  );

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.event_id, 42);
  assert.equal(state.insertCalls, 1);
  assert.equal(state.lastBindValues?.[0], "activation_outcome");
});

test("persists runtime transport diagnostics telemetry event types", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "runtime_transport_error",
      message: "Runtime transport unavailable",
      timestamp: "2026-02-16T12:03:00.000Z",
      payload: {
        endpoint: "http://localhost:9133/telemetry",
      },
    }),
    env,
  );

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.event_id, 42);
  assert.equal(state.insertCalls, 1);
  assert.equal(state.lastBindValues?.[0], "runtime_transport_error");
});

test("drops legacy daemon ipc telemetry event types", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "daemon_ipc_error",
      message: "Legacy daemon IPC error",
      timestamp: "2026-02-16T12:03:00.000Z",
      payload: {
        endpoint: "unix:///tmp/capacitor.sock",
      },
    }),
    env,
  );

  assert.equal(response.status, 202);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.dropped, true);
  assert.equal(body.reason, "event_type_not_allowed");
  assert.equal(state.insertCalls, 0);
});

test("drops duplicate activation diagnostics telemetry events within throttle window", async () => {
  const { env, state } = makeEnv();

  const first = await worker.fetch(
    telemetryRequest({
      type: "activation_outcome",
      message: "snapshot_unavailable_fallback",
      timestamp: "2026-02-16T12:03:00.000Z",
      payload: {
        success: true,
      },
    }),
    env,
  );
  assert.equal(first.status, 200);

  const second = await worker.fetch(
    telemetryRequest({
      type: "activation_outcome",
      message: "snapshot_unavailable_fallback",
      timestamp: "2026-02-16T12:03:01.000Z",
      payload: {
        success: true,
      },
    }),
    env,
  );

  assert.equal(second.status, 202);
  const body = await second.json();
  assert.equal(body.ok, true);
  assert.equal(body.dropped, true);
  assert.equal(body.reason, "duplicate_throttled");
  assert.equal(state.insertCalls, 1);
});

test("drops unknown quick feedback event types not on allowlist", async () => {
  const { env, state } = makeEnv();

  const response = await worker.fetch(
    telemetryRequest({
      type: "quick_feedback_experimental_event",
      message: "Unexpected quick feedback event",
      timestamp: "2026-02-16T12:02:00.000Z",
      payload: {
        feedback_id: "fb-124",
      },
    }),
    env,
  );

  assert.equal(response.status, 202);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.dropped, true);
  assert.equal(body.reason, "event_type_not_allowed");
  assert.equal(state.insertCalls, 0);
});

test("scheduled cleanup applies telemetry retention deletes using received_at", async () => {
  const { env, state } = makeEnv();
  const pending = [];

  await worker.scheduled(
    {},
    env,
    {
      waitUntil(promise) {
        pending.push(promise);
      },
    },
  );

  await Promise.all(pending);
  assert.equal(state.cleanupStatements.length, 3);
  assert.match(state.cleanupStatements[0], /event_type NOT IN/i);
  assert.match(state.cleanupStatements[1], /event_type IN/i);
  assert.match(state.cleanupStatements[2], /event_type IN/i);
  // All three DELETE statements should use received_at, not occurred_at
  for (const stmt of state.cleanupStatements) {
    assert.match(stmt, /received_at/, "DELETE should reference received_at for retention");
    assert.doesNotMatch(stmt, /occurred_at/, "DELETE should not reference occurred_at for retention");
  }
});

test("retention cleanup prunes by received_at regardless of occurred_at value", async () => {
  // This test verifies the conceptual guarantee: an event with a future-dated
  // occurred_at (client timestamp) should still be pruned based on received_at
  // (server timestamp). We verify by checking the SQL uses received_at.
  const { env, state } = makeEnv();
  const pending = [];

  await worker.scheduled(
    {},
    env,
    {
      waitUntil(promise) {
        pending.push(promise);
      },
    },
  );

  await Promise.all(pending);

  // The DELETE WHERE clauses should only reference received_at for time comparison,
  // so a row with occurred_at far in the future but received_at in the past would
  // still be deleted. We verify this by confirming the SQL shape.
  for (const stmt of state.cleanupStatements) {
    // Should contain received_at in the datetime comparison
    assert.match(stmt, /datetime\(received_at\)/i);
    // Should NOT contain occurred_at in the datetime comparison
    assert.doesNotMatch(stmt, /datetime\(occurred_at\)/i);
  }
});

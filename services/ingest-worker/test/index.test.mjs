import assert from "node:assert/strict";
import test from "node:test";

import worker from "../src/index.js";

function makeEnv() {
  const state = {
    insertCalls: 0,
    lastBindValues: null,
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

                if (normalized.includes("insert into telemetry_events")) {
                  state.insertCalls += 1;
                  state.events.push({
                    event_type: values[0],
                    message: values[1],
                    feedback_id: values[3] ?? null,
                    source_ip: values[6] ?? null,
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

test("scheduled cleanup applies telemetry retention deletes", async () => {
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
});

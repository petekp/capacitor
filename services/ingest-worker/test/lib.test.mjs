import assert from "node:assert/strict";
import test from "node:test";

import {
  hashIP,
  isAuthorized,
  normalizeFeedbackID,
  normalizeFeedbackSubmission,
  normalizeTelemetryEvent,
} from "../src/lib.js";

const requestWithHeaders = (headers = {}) =>
  new Request("https://ingest.example.com/v1/feedback", { headers });

test("isAuthorized validates bearer token", () => {
  const req = requestWithHeaders({ authorization: "Bearer secret" });
  assert.equal(isAuthorized(req.headers, "secret"), true);
  assert.equal(isAuthorized(req.headers, "other"), false);
  assert.equal(isAuthorized(req.headers, ""), false);
});

test("normalizeFeedbackID preserves provided id", () => {
  assert.equal(normalizeFeedbackID("fb-custom-1"), "fb-custom-1");
});

test("hashIP returns null for null input", async () => {
  assert.equal(await hashIP(null), null);
});

test("hashIP returns a 16-char hex string for a valid IP", async () => {
  const result = await hashIP("203.0.113.10");
  assert.equal(typeof result, "string");
  assert.equal(result.length, 16);
  assert.match(result, /^[0-9a-f]{16}$/);
});

test("hashIP is deterministic for the same input", async () => {
  const a = await hashIP("203.0.113.10");
  const b = await hashIP("203.0.113.10");
  assert.equal(a, b);
});

test("hashIP produces different hashes for different IPs", async () => {
  const a = await hashIP("203.0.113.10");
  const b = await hashIP("203.0.113.11");
  assert.notEqual(a, b);
});

test("normalizeFeedbackSubmission extracts structured fields", async () => {
  const request = requestWithHeaders({
    "cf-connecting-ip": "203.0.113.10",
    "user-agent": "Capacitor/0.2",
  });

  const body = {
    feedback_id: "fb-123",
    submittedAt: "2026-02-16T12:00:00.000Z",
    form: {
      summary: "Issue with routing",
    },
    app: {
      version: "0.2.0",
      buildNumber: "42",
      channel: "alpha",
      osVersion: "macOS 15",
    },
    privacy: {
      includeTelemetry: true,
      includeProjectPaths: false,
    },
    projectContext: {
      activeSource: "claude",
      projectCount: 3,
      sessionSummary: {
        total: 3,
        working: 1,
        ready: 1,
        waiting: 1,
        compacting: 0,
        idle: 0,
        withAttachedSession: 2,
        thinking: 1,
      },
    },
    activationSignal: {
      hasTrace: true,
      traceDigest: "abc",
    },
  };

  const normalized = await normalizeFeedbackSubmission(body, request);
  assert.equal(normalized.feedback_id, "fb-123");
  assert.equal(normalized.feedback_text, "Issue with routing");
  assert.equal(normalized.include_telemetry, 1);
  assert.equal(normalized.include_project_paths, 0);
  assert.equal(normalized.project_count, 3);
  // source_ip should be a hash, not the raw IP
  assert.notEqual(normalized.source_ip, "203.0.113.10");
  assert.match(normalized.source_ip, /^[0-9a-f]{16}$/);
  // raw_json should not be present
  assert.equal(Object.hasOwn(normalized, "raw_json"), false);
});

test("normalizeFeedbackSubmission uses runtime snapshot fields and ignores legacy daemon fields", async () => {
  const request = requestWithHeaders({
    "cf-connecting-ip": "203.0.113.10",
    "user-agent": "Capacitor/0.2",
  });

  const body = {
    feedback_id: "fb-123",
    submittedAt: "2026-02-16T12:00:00.000Z",
    form: {
      summary: "Issue with routing",
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
  };

  const normalized = await normalizeFeedbackSubmission(body, request);
  assert.equal(normalized.runtime_enabled, 1);
  assert.equal(normalized.runtime_healthy, 0);
  assert.equal(normalized.runtime_version, "1.2.3");
  assert.equal(Object.hasOwn(normalized, "daemon_enabled"), false);
  assert.equal(Object.hasOwn(normalized, "daemon_healthy"), false);
  assert.equal(Object.hasOwn(normalized, "daemon_version"), false);
});

test("normalizeTelemetryEvent links feedback id from payload", async () => {
  const request = requestWithHeaders({ "user-agent": "Capacitor/0.2" });
  const body = {
    type: "quick_feedback_submitted",
    message: "Quick feedback submitted",
    timestamp: "2026-02-16T12:01:00.000Z",
    payload: {
      feedback_id: "fb-123",
      issue_opened: true,
    },
  };

  const normalized = await normalizeTelemetryEvent(body, request);
  assert.equal(normalized.event_type, "quick_feedback_submitted");
  assert.equal(normalized.feedback_id, "fb-123");
  assert.match(normalized.payload_json, /issue_opened/);
  // raw_json should not be present
  assert.equal(Object.hasOwn(normalized, "raw_json"), false);
  // source_ip should be null (no cf-connecting-ip header)
  assert.equal(normalized.source_ip, null);
});

test("normalizeTelemetryEvent hashes source_ip when present", async () => {
  const request = requestWithHeaders({
    "cf-connecting-ip": "10.0.0.1",
    "user-agent": "Capacitor/0.2",
  });
  const body = {
    type: "activation_outcome",
    message: "test",
    timestamp: "2026-02-16T12:01:00.000Z",
    payload: {},
  };

  const normalized = await normalizeTelemetryEvent(body, request);
  assert.notEqual(normalized.source_ip, "10.0.0.1");
  assert.match(normalized.source_ip, /^[0-9a-f]{16}$/);
});

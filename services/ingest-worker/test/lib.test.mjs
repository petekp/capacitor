import assert from "node:assert/strict";
import test from "node:test";

import {
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

test("normalizeFeedbackSubmission extracts structured fields", () => {
  const request = requestWithHeaders({
    "cf-connecting-ip": "203.0.113.10",
    "user-agent": "Capacitor/0.2",
  });

  const body = {
    feedback_id: "fb-123",
    submittedAt: "2026-02-16T12:00:00.000Z",
    feedback: "Issue with routing",
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

  const normalized = normalizeFeedbackSubmission(body, request);
  assert.equal(normalized.feedback_id, "fb-123");
  assert.equal(normalized.feedback_text, "Issue with routing");
  assert.equal(normalized.include_telemetry, 1);
  assert.equal(normalized.include_project_paths, 0);
  assert.equal(normalized.project_count, 3);
  assert.equal(normalized.source_ip, "203.0.113.10");
});

test("normalizeTelemetryEvent links feedback id from payload", () => {
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

  const normalized = normalizeTelemetryEvent(body, request);
  assert.equal(normalized.event_type, "quick_feedback_submitted");
  assert.equal(normalized.feedback_id, "fb-123");
  assert.match(normalized.payload_json, /issue_opened/);
});

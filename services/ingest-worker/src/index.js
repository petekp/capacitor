import {
  asObject,
  isAuthorized,
  normalizeFeedbackSubmission,
  normalizeTelemetryEvent,
} from "./lib.js";

const ALLOWED_TELEMETRY_EVENT_TYPES = new Set([
  "quick_feedback_opened",
  "quick_feedback_field_completed",
  "quick_feedback_submit_attempt",
  "quick_feedback_submit_success",
  "quick_feedback_submit_failure",
  "quick_feedback_abandoned",
  "quick_feedback_submitted",
  "activation_decision",
  "activation_outcome",
  "runtime_transport_error",
  "routing_snapshot_refresh_error",
]);

const DUPLICATE_THROTTLE_EVENT_TYPES = new Set([
  "activation_decision",
  "activation_outcome",
  "runtime_transport_error",
  "routing_snapshot_refresh_error",
]);

const DUPLICATE_THROTTLE_WINDOW_SECONDS = 5;
const LEGACY_EVENT_RETENTION_DAYS = 1;
const HIGH_VOLUME_EVENT_RETENTION_DAYS = 30;
const DIAGNOSTIC_EVENT_RETENTION_DAYS = 90;

const HIGH_VOLUME_TELEMETRY_EVENT_TYPES = [
  "quick_feedback_opened",
  "quick_feedback_field_completed",
  "quick_feedback_submit_attempt",
  "quick_feedback_submit_success",
  "quick_feedback_submit_failure",
  "quick_feedback_abandoned",
];

const DIAGNOSTIC_TELEMETRY_EVENT_TYPES = [
  "quick_feedback_submitted",
  "activation_decision",
  "activation_outcome",
  "runtime_transport_error",
  "routing_snapshot_refresh_error",
];

function sqlInList(values) {
  return values.map((value) => `'${value.replace(/'/g, "''")}'`).join(", ");
}

const ALLOWED_TELEMETRY_SQL_LIST = sqlInList([...ALLOWED_TELEMETRY_EVENT_TYPES]);
const HIGH_VOLUME_TELEMETRY_SQL_LIST = sqlInList(HIGH_VOLUME_TELEMETRY_EVENT_TYPES);
const DIAGNOSTIC_TELEMETRY_SQL_LIST = sqlInList(DIAGNOSTIC_TELEMETRY_EVENT_TYPES);

function withCors(headers = {}) {
  return {
    "access-control-allow-origin": "*",
    "access-control-allow-methods": "POST, OPTIONS",
    "access-control-allow-headers": "authorization, content-type",
    ...headers,
  };
}

function jsonResponse(status, payload) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: withCors({ "content-type": "application/json" }),
  });
}

async function readJson(request) {
  try {
    const parsed = await request.json();
    return { ok: true, body: asObject(parsed) };
  } catch {
    return { ok: false, body: null };
  }
}

/**
 * @param {Env} env
 * @param {ReturnType<typeof normalizeTelemetryEvent>} event
 */
async function isDuplicateTelemetryEvent(env, event) {
  if (!DUPLICATE_THROTTLE_EVENT_TYPES.has(event.event_type)) {
    return false;
  }

  const result = await env.DB.prepare(
    `SELECT 1 AS found
     FROM telemetry_events
     WHERE event_type = ?
       AND message = ?
       AND COALESCE(feedback_id, '') = COALESCE(?, '')
       AND COALESCE(source_ip, '') = COALESCE(?, '')
       AND datetime(received_at) >= datetime('now', ?)
     ORDER BY id DESC
     LIMIT 1`,
  )
    .bind(
      event.event_type,
      event.message,
      event.feedback_id,
      event.source_ip,
      `-${DUPLICATE_THROTTLE_WINDOW_SECONDS} seconds`,
    )
    .run();

  return Array.isArray(result.results) && result.results.length > 0;
}

/**
 * @param {Env} env
 */
export async function pruneTelemetryEvents(env) {
  const result = {
    legacyDeleted: 0,
    highVolumeDeleted: 0,
    diagnosticDeleted: 0,
  };

  const legacy = await env.DB.prepare(
    `DELETE FROM telemetry_events
     WHERE event_type NOT IN (${ALLOWED_TELEMETRY_SQL_LIST})
       AND datetime(received_at) < datetime('now', '-${LEGACY_EVENT_RETENTION_DAYS} days')`,
  ).run();
  result.legacyDeleted = legacy.meta?.changes ?? 0;

  const highVolume = await env.DB.prepare(
    `DELETE FROM telemetry_events
     WHERE event_type IN (${HIGH_VOLUME_TELEMETRY_SQL_LIST})
       AND datetime(received_at) < datetime('now', '-${HIGH_VOLUME_EVENT_RETENTION_DAYS} days')`,
  ).run();
  result.highVolumeDeleted = highVolume.meta?.changes ?? 0;

  const diagnostics = await env.DB.prepare(
    `DELETE FROM telemetry_events
     WHERE event_type IN (${DIAGNOSTIC_TELEMETRY_SQL_LIST})
       AND datetime(received_at) < datetime('now', '-${DIAGNOSTIC_EVENT_RETENTION_DAYS} days')`,
  ).run();
  result.diagnosticDeleted = diagnostics.meta?.changes ?? 0;

  return result;
}

/**
 * @param {Request} request
 * @param {Env} env
 */
async function handleFeedback(request, env) {
  const parsed = await readJson(request);
  if (!parsed.ok) {
    return jsonResponse(400, { ok: false, error: "invalid_json" });
  }

  const record = await normalizeFeedbackSubmission(parsed.body, request);
  if (!record.feedback_text) {
    return jsonResponse(422, { ok: false, error: "feedback_required" });
  }

  await env.DB.prepare(
    `INSERT INTO feedback_submissions (
      feedback_id,
      submitted_at,
      feedback_text,
      app_version,
      build_number,
      channel,
      os_version,
      include_telemetry,
      include_project_paths,
      runtime_enabled,
      runtime_healthy,
      runtime_version,
      active_source,
      project_count,
      session_total,
      session_working,
      session_ready,
      session_waiting,
      session_compacting,
      session_idle,
      session_with_attached,
      session_thinking,
      activation_has_trace,
      activation_trace_digest,
      source_ip,
      user_agent,
      last_received_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, datetime('now'))
    ON CONFLICT(feedback_id) DO UPDATE SET
      submitted_at = excluded.submitted_at,
      feedback_text = excluded.feedback_text,
      app_version = excluded.app_version,
      build_number = excluded.build_number,
      channel = excluded.channel,
      os_version = excluded.os_version,
      include_telemetry = excluded.include_telemetry,
      include_project_paths = excluded.include_project_paths,
      runtime_enabled = excluded.runtime_enabled,
      runtime_healthy = excluded.runtime_healthy,
      runtime_version = excluded.runtime_version,
      active_source = excluded.active_source,
      project_count = excluded.project_count,
      session_total = excluded.session_total,
      session_working = excluded.session_working,
      session_ready = excluded.session_ready,
      session_waiting = excluded.session_waiting,
      session_compacting = excluded.session_compacting,
      session_idle = excluded.session_idle,
      session_with_attached = excluded.session_with_attached,
      session_thinking = excluded.session_thinking,
      activation_has_trace = excluded.activation_has_trace,
      activation_trace_digest = excluded.activation_trace_digest,
      source_ip = excluded.source_ip,
      user_agent = excluded.user_agent,
      last_received_at = datetime('now')`,
  )
    .bind(
      record.feedback_id,
      record.submitted_at,
      record.feedback_text,
      record.app_version,
      record.build_number,
      record.channel,
      record.os_version,
      record.include_telemetry,
      record.include_project_paths,
      record.runtime_enabled,
      record.runtime_healthy,
      record.runtime_version,
      record.active_source,
      record.project_count,
      record.session_total,
      record.session_working,
      record.session_ready,
      record.session_waiting,
      record.session_compacting,
      record.session_idle,
      record.session_with_attached,
      record.session_thinking,
      record.activation_has_trace,
      record.activation_trace_digest,
      record.source_ip,
      record.user_agent,
    )
    .run();

  return jsonResponse(200, { ok: true, feedback_id: record.feedback_id });
}

/**
 * @param {Request} request
 * @param {Env} env
 */
async function handleTelemetry(request, env) {
  const parsed = await readJson(request);
  if (!parsed.ok) {
    return jsonResponse(400, { ok: false, error: "invalid_json" });
  }

  const event = await normalizeTelemetryEvent(parsed.body, request);
  if (!ALLOWED_TELEMETRY_EVENT_TYPES.has(event.event_type)) {
    return jsonResponse(202, {
      ok: true,
      dropped: true,
      reason: "event_type_not_allowed",
    });
  }

  if (await isDuplicateTelemetryEvent(env, event)) {
    return jsonResponse(202, {
      ok: true,
      dropped: true,
      reason: "duplicate_throttled",
    });
  }

  const result = await env.DB.prepare(
    `INSERT INTO telemetry_events (
      event_type,
      message,
      occurred_at,
      feedback_id,
      payload_json,
      source_ip,
      user_agent
    ) VALUES (?, ?, ?, ?, ?, ?, ?)`,
  )
    .bind(
      event.event_type,
      event.message,
      event.occurred_at,
      event.feedback_id,
      event.payload_json,
      event.source_ip,
      event.user_agent,
    )
    .run();

  return jsonResponse(200, {
    ok: true,
    event_id: result.meta?.last_row_id ?? null,
  });
}

export default {
  /**
   * @param {Request} request
   * @param {Env} env
   */
  async fetch(request, env) {
    if (request.method === "OPTIONS") {
      return new Response(null, { status: 204, headers: withCors() });
    }

    const url = new URL(request.url);

    if (url.pathname === "/health") {
      return jsonResponse(200, {
        ok: true,
        service: "capacitor-ingest-worker",
        timestamp: new Date().toISOString(),
      });
    }

    if (!url.pathname.startsWith("/v1/")) {
      return jsonResponse(404, { ok: false, error: "not_found" });
    }

    if (request.method !== "POST") {
      return jsonResponse(405, { ok: false, error: "method_not_allowed" });
    }

    if (!isAuthorized(request.headers, env.INGEST_KEY)) {
      return jsonResponse(401, { ok: false, error: "unauthorized" });
    }

    if (url.pathname === "/v1/feedback") {
      return handleFeedback(request, env);
    }

    if (url.pathname === "/v1/telemetry") {
      return handleTelemetry(request, env);
    }

    return jsonResponse(404, { ok: false, error: "not_found" });
  },

  /**
   * @param {ScheduledController} _controller
   * @param {Env} env
   * @param {ExecutionContext} ctx
   */
  async scheduled(_controller, env, ctx) {
    ctx.waitUntil(pruneTelemetryEvents(env));
  },
};

/**
 * @typedef {object} Env
 * @property {D1Database} DB
 * @property {string} INGEST_KEY
 */

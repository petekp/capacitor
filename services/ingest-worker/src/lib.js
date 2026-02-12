const FEEDBACK_ID_PREFIX = "fb-";

/**
 * @param {Headers} headers
 * @param {string | undefined} ingestKey
 */
export function isAuthorized(headers, ingestKey) {
  if (!ingestKey || !ingestKey.trim()) {
    return false;
  }

  const authHeader = headers.get("authorization") || "";
  if (!authHeader.startsWith("Bearer ")) {
    return false;
  }

  const token = authHeader.slice("Bearer ".length).trim();
  return token.length > 0 && token === ingestKey;
}

/**
 * @param {unknown} value
 */
export function asObject(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {};
}

/**
 * @param {unknown} value
 */
export function asString(value) {
  return typeof value === "string" ? value : null;
}

/**
 * @param {unknown} value
 */
export function asInteger(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return Math.trunc(value);
  }
  return null;
}

/**
 * @param {unknown} value
 */
export function asBoolInt(value) {
  return value === true ? 1 : 0;
}

/**
 * @param {unknown} candidate
 */
export function normalizeFeedbackID(candidate) {
  if (typeof candidate !== "string") {
    return `${FEEDBACK_ID_PREFIX}${crypto.randomUUID()}`;
  }

  const trimmed = candidate.trim();
  if (!trimmed) {
    return `${FEEDBACK_ID_PREFIX}${crypto.randomUUID()}`;
  }

  return trimmed;
}

/**
 * @param {Record<string, unknown>} body
 * @param {Request} request
 */
export function normalizeFeedbackSubmission(body, request) {
  const app = asObject(body.app);
  const privacy = asObject(body.privacy);
  const daemon = asObject(body.daemon);
  const projectContext = asObject(body.projectContext);
  const sessionSummary = asObject(projectContext.sessionSummary);
  const activationSignal = asObject(body.activationSignal);

  return {
    feedback_id: normalizeFeedbackID(body.feedback_id),
    submitted_at: asString(body.submittedAt) || new Date().toISOString(),
    feedback_text: (asString(body.feedback) || "").trim(),
    app_version: asString(app.version),
    build_number: asString(app.buildNumber),
    channel: asString(app.channel),
    os_version: asString(app.osVersion),
    include_telemetry: asBoolInt(privacy.includeTelemetry),
    include_project_paths: asBoolInt(privacy.includeProjectPaths),
    daemon_enabled: daemon.enabled === undefined ? null : asBoolInt(daemon.enabled),
    daemon_healthy: daemon.healthy === undefined ? null : asBoolInt(daemon.healthy),
    daemon_version: asString(daemon.version),
    active_source: asString(projectContext.activeSource),
    project_count: asInteger(projectContext.projectCount),
    session_total: asInteger(sessionSummary.total),
    session_working: asInteger(sessionSummary.working),
    session_ready: asInteger(sessionSummary.ready),
    session_waiting: asInteger(sessionSummary.waiting),
    session_compacting: asInteger(sessionSummary.compacting),
    session_idle: asInteger(sessionSummary.idle),
    session_with_attached: asInteger(sessionSummary.withAttachedSession),
    session_thinking: asInteger(sessionSummary.thinking),
    activation_has_trace: asBoolInt(activationSignal.hasTrace),
    activation_trace_digest: asString(activationSignal.traceDigest),
    source_ip: request.headers.get("cf-connecting-ip"),
    user_agent: request.headers.get("user-agent"),
    raw_json: JSON.stringify(body),
  };
}

/**
 * @param {Record<string, unknown>} body
 * @param {Request} request
 */
export function normalizeTelemetryEvent(body, request) {
  const payload = asObject(body.payload);

  return {
    event_type: asString(body.type) || "unknown",
    message: asString(body.message) || "",
    occurred_at: asString(body.timestamp) || new Date().toISOString(),
    feedback_id: asString(payload.feedback_id) || asString(body.feedback_id),
    payload_json: JSON.stringify(payload),
    raw_json: JSON.stringify(body),
    source_ip: request.headers.get("cf-connecting-ip"),
    user_agent: request.headers.get("user-agent"),
  };
}

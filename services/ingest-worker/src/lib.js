const FEEDBACK_ID_PREFIX = "fb-";

// Static salt prevents rainbow-table reversal of the ~4B IPv4 address space.
// Not a secret — just makes precomputation infeasible without knowing the salt.
const IP_HASH_SALT = "capacitor-ingest-v1";

/**
 * Hash an IP address using salted SHA-256 and return the first 16 hex characters.
 * Returns null if no IP is provided.
 * @param {string | null} ip
 */
export async function hashIP(ip) {
  if (!ip) return null;
  const data = new TextEncoder().encode(IP_HASH_SALT + ip);
  const hash = await crypto.subtle.digest("SHA-256", data);
  const hex = [...new Uint8Array(hash)]
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  return hex.substring(0, 16);
}

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
export async function normalizeFeedbackSubmission(body, request) {
  const app = asObject(body.app);
  const form = asObject(body.form);
  const privacy = asObject(body.privacy);
  const runtime = asObject(body.runtime);
  const projectContext = asObject(body.projectContext);
  const sessionSummary = asObject(projectContext.sessionSummary);
  const activationSignal = asObject(body.activationSignal);

  return {
    feedback_id: normalizeFeedbackID(body.feedback_id),
    submitted_at: asString(body.submittedAt) || new Date().toISOString(),
    feedback_text: (asString(form.summary) || "").trim(),
    app_version: asString(app.version),
    build_number: asString(app.buildNumber),
    channel: asString(app.channel),
    os_version: asString(app.osVersion),
    include_telemetry: asBoolInt(privacy.includeTelemetry),
    include_project_paths: asBoolInt(privacy.includeProjectPaths),
    runtime_enabled: runtime.enabled === undefined ? null : asBoolInt(runtime.enabled),
    runtime_healthy: runtime.healthy === undefined ? null : asBoolInt(runtime.healthy),
    runtime_version: asString(runtime.version),
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
    source_ip: await hashIP(request.headers.get("cf-connecting-ip")),
    user_agent: request.headers.get("user-agent"),
  };
}

/**
 * @param {Record<string, unknown>} body
 * @param {Request} request
 */
export async function normalizeTelemetryEvent(body, request) {
  const payload = asObject(body.payload);

  return {
    event_type: asString(body.type) || "unknown",
    message: asString(body.message) || "",
    occurred_at: asString(body.timestamp) || new Date().toISOString(),
    feedback_id: asString(payload.feedback_id) || asString(body.feedback_id),
    payload_json: JSON.stringify(payload),
    source_ip: await hashIP(request.headers.get("cf-connecting-ip")),
    user_agent: request.headers.get("user-agent"),
  };
}

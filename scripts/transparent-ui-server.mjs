#!/usr/bin/env node
import fs from "fs/promises";
import http from "http";
import os from "os";
import path from "path";

const PORT = Number(process.env.PORT || 9133);
const RUNTIME_DIR = path.join(os.homedir(), ".capacitor", "runtime");
const RUNTIME_ARTIFACT_PATH = process.env.CAPACITOR_RUNTIME_ARTIFACT_PATH
  || path.join(RUNTIME_DIR, "app_snapshot.json");
const RUNTIME_SERVICE_CONNECTION_PATH = process.env.CAPACITOR_RUNTIME_SERVICE_CONNECTION_PATH
  || path.join(RUNTIME_DIR, "runtime-service.json");
const TELEMETRY_LIMIT = Number(process.env.CAPACITOR_TELEMETRY_LIMIT || 500);
const BRIEFING_SHELL_LIMIT = Number(process.env.CAPACITOR_BRIEFING_SHELL_LIMIT || 25);

const telemetryClients = new Set();
const telemetryEvents = [];

function parseBoundedPositiveInt(rawValue, fallback, max) {
  const parsed = Number(rawValue);
  if (!Number.isFinite(parsed)) return fallback;
  const floored = Math.floor(parsed);
  if (floored <= 0) return fallback;
  return Math.min(floored, max);
}

function jsonResponse(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*"
  });
  res.end(body);
}

function sendSse(res, payload) {
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function broadcastTelemetry(payload) {
  telemetryClients.forEach(res => {
    try {
      sendSse(res, payload);
    } catch {
      telemetryClients.delete(res);
    }
  });
}

function addTelemetryEvent(event) {
  const receivedAt = new Date().toISOString();
  const entry = {
    id: `telemetry-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`,
    received_at: receivedAt,
    ...event
  };
  telemetryEvents.unshift(entry);
  if (telemetryEvents.length > TELEMETRY_LIMIT) {
    telemetryEvents.length = TELEMETRY_LIMIT;
  }
  broadcastTelemetry(entry);
}

function parseTimestamp(value) {
  if (!value) return 0;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function parseRoutingParams(url) {
  const projectPath = (url.searchParams.get("project_path") || "").trim();
  const workspaceId = (url.searchParams.get("workspace_id") || "").trim() || undefined;
  return { projectPath, workspaceId };
}

function trimString(value) {
  return typeof value === "string" ? value.trim() : "";
}

async function discoverRuntimeServiceConnection() {
  const envPort = trimString(process.env.CAPACITOR_RUNTIME_SERVICE_PORT);
  const envToken = trimString(process.env.CAPACITOR_RUNTIME_SERVICE_TOKEN);
  if (envPort && envToken) {
    return {
      baseURL: `http://127.0.0.1:${envPort}`,
      authToken: envToken,
      source: "env"
    };
  }

  try {
    const payload = JSON.parse(await fs.readFile(RUNTIME_SERVICE_CONNECTION_PATH, "utf8"));
    const port = trimString(String(payload.port ?? ""));
    const authToken = trimString(payload.auth_token);
    if (port && authToken) {
      return {
        baseURL: `http://127.0.0.1:${port}`,
        authToken,
        source: "connection_file"
      };
    }
  } catch {
    return null;
  }

  return null;
}

function requestJson(url, headers = {}) {
  return new Promise((resolve, reject) => {
    const request = http.request(url, { method: "GET", headers }, res => {
      let body = "";
      res.on("data", chunk => {
        body += chunk.toString("utf8");
      });
      res.on("end", () => {
        if ((res.statusCode || 500) !== 200) {
          reject(new Error(`HTTP ${res.statusCode || 500}: ${body || "request failed"}`));
          return;
        }

        try {
          resolve(JSON.parse(body));
        } catch (error) {
          reject(error);
        }
      });
    });

    request.on("error", reject);
    request.end();
  });
}

function normalizeRuntimeSnapshot(snapshot) {
  return {
    projects: Array.isArray(snapshot.projects) ? snapshot.projects : [],
    sessions: Array.isArray(snapshot.sessions) ? snapshot.sessions : [],
    shells: Array.isArray(snapshot.shells) ? snapshot.shells : [],
    routing: Array.isArray(snapshot.routing) ? snapshot.routing : [],
    diagnostics: snapshot.diagnostics && typeof snapshot.diagnostics === "object"
      ? snapshot.diagnostics
      : null,
    generated_at: typeof snapshot.generated_at === "string" ? snapshot.generated_at : null
  };
}

async function readArtifactSnapshot() {
  const payload = await fs.readFile(RUNTIME_ARTIFACT_PATH, "utf8");
  return normalizeRuntimeSnapshot(JSON.parse(payload));
}

async function readRuntimeSnapshot() {
  const runtimeService = await discoverRuntimeServiceConnection();
  if (runtimeService) {
    const snapshot = await requestJson(
      `${runtimeService.baseURL}/runtime/snapshot`,
      { Authorization: `Bearer ${runtimeService.authToken}` }
    );
    return {
      ...normalizeRuntimeSnapshot(snapshot),
      source: "runtime_service",
      runtime_service: {
        base_url: runtimeService.baseURL,
        source: runtimeService.source
      }
    };
  }

  return {
    ...await readArtifactSnapshot(),
    source: "artifact_file",
    runtime_service: null
  };
}

async function readRuntimeHealth(runtimeSnapshot) {
  if (runtimeSnapshot.source === "runtime_service" && runtimeSnapshot.runtime_service) {
    const connection = await discoverRuntimeServiceConnection();
    const health = await requestJson(
      `${connection.baseURL}/health`,
      { Authorization: `Bearer ${connection.authToken}` }
    );
    return {
      ...health,
      source: "runtime_service",
      endpoint: `${connection.baseURL}/health`
    };
  }

  return {
    status: "healthy",
    pid: null,
    version: "artifact-fallback",
    generated_at: runtimeSnapshot.generated_at,
    source: "artifact_file",
    endpoint: null
  };
}

function normalizeShells(shells, options = {}) {
  const mode = options.mode === "all" ? "all" : "recent";
  const limit = Number.isFinite(options.limit) && options.limit > 0
    ? options.limit
    : BRIEFING_SHELL_LIMIT;

  const sorted = [...shells].sort((a, b) => parseTimestamp(b?.updated_at) - parseTimestamp(a?.updated_at));
  const selected = mode === "all" ? sorted : sorted.slice(0, limit);

  return {
    shells: selected,
    total_count: sorted.length,
    recent_count: selected.length,
    selection: mode,
    selection_limit: mode === "all" ? sorted.length : limit
  };
}

function chooseRoutingProjectPath(projects = [], sessions = []) {
  const workingProject = projects
    .filter(entry => String(entry?.state || "").toLowerCase() === "working")
    .sort((a, b) => parseTimestamp(b?.updated_at) - parseTimestamp(a?.updated_at))[0];

  if (workingProject?.project_path) {
    return workingProject.project_path;
  }

  const recentSession = sessions
    .filter(entry => typeof entry?.project_path === "string" && entry.project_path.length > 0)
    .sort((a, b) => parseTimestamp(b?.updated_at) - parseTimestamp(a?.updated_at))[0];

  if (recentSession?.project_path) {
    return recentSession.project_path;
  }

  return projects.find(entry => entry?.project_path)?.project_path || null;
}

function findRoutingEntry(routing, projectPath, workspaceId) {
  if (!projectPath) return null;

  const exact = routing.find(entry => {
    if (entry?.project_path !== projectPath) return false;
    if (workspaceId && entry?.workspace_id !== workspaceId) return false;
    return true;
  });

  if (exact) return exact;

  if (!workspaceId) {
    return routing.find(entry => entry?.project_path === projectPath) || null;
  }

  return null;
}

async function buildSnapshot(options = {}) {
  try {
    const runtime = await readRuntimeSnapshot();
    const health = await readRuntimeHealth(runtime);

    const shellState = normalizeShells(runtime.shells, {
      mode: options.shellsMode || "all",
      limit: options.shellLimit
    });

    const projectPath = options.projectPath || chooseRoutingProjectPath(runtime.projects, runtime.sessions);
    const workspaceId = options.workspaceId;
    const routingSnapshot = findRoutingEntry(runtime.routing, projectPath, workspaceId);

    return {
      ok: true,
      timestamp: new Date().toISOString(),
      sessions: runtime.sessions,
      project_states: runtime.projects,
      activity: runtime.sessions
        .slice()
        .sort((a, b) => parseTimestamp(b?.updated_at) - parseTimestamp(a?.updated_at))
        .slice(0, 120),
      shell_state: shellState,
      health,
      routing: {
        project_path: projectPath,
        workspace_id: workspaceId || null,
        snapshot: routingSnapshot,
        diagnostics: runtime.diagnostics,
        rollout: null,
        health: null
      },
      runtime_source: runtime.source,
      runtime_service: runtime.runtime_service,
      artifact_path: RUNTIME_ARTIFACT_PATH,
      runtime_snapshot_location: runtime.source === "runtime_service" && runtime.runtime_service
        ? `${runtime.runtime_service.base_url}/runtime/snapshot`
        : RUNTIME_ARTIFACT_PATH
    };
  } catch (error) {
    return {
      ok: false,
      error: String(error),
      timestamp: new Date().toISOString(),
      artifact_path: RUNTIME_ARTIFACT_PATH
    };
  }
}

async function buildBriefing(options = {}) {
  const limit = parseBoundedPositiveInt(options.limit, 200, TELEMETRY_LIMIT);
  const shellsMode = options.shellsMode === "all" ? "all" : "recent";
  const shellLimit = parseBoundedPositiveInt(
    options.shellLimit,
    BRIEFING_SHELL_LIMIT,
    Number.MAX_SAFE_INTEGER
  );

  const snapshot = await buildSnapshot({
    shellsMode,
    shellLimit,
    projectPath: options.projectPath,
    workspaceId: options.workspaceId
  });

  const sessions = Array.isArray(snapshot.sessions) ? snapshot.sessions : [];
  const projects = Array.isArray(snapshot.project_states) ? snapshot.project_states : [];
  const shellState = snapshot.shell_state || {};
  const health = snapshot.health && typeof snapshot.health === "object" ? snapshot.health : null;
  const routing = snapshot.routing || {};

  const telemetry = telemetryEvents.slice(0, limit);

  return {
    ok: Boolean(snapshot && snapshot.ok),
    timestamp: new Date().toISOString(),
    snapshot,
    error: snapshot && snapshot.ok ? null : snapshot && snapshot.error ? snapshot.error : "snapshot_unavailable",
    telemetry,
    summary: {
      sessions: { count: sessions.length },
      projects: { count: projects.length },
      shells: {
        total: Number.isFinite(shellState.total_count) ? shellState.total_count : 0,
        recent: Number.isFinite(shellState.recent_count) ? shellState.recent_count : 0,
        mode: shellState.selection || shellsMode,
        limit: shellState.selection_limit || shellLimit
      },
      runtime: {
        status: health && typeof health.status === "string" ? health.status : "unknown",
        generated_at: health && typeof health.generated_at === "string" ? health.generated_at : null,
        source: snapshot.runtime_source || "unknown",
        artifact_path: RUNTIME_ARTIFACT_PATH,
        snapshot_location: snapshot.runtime_snapshot_location || RUNTIME_ARTIFACT_PATH
      },
      routing: {
        project_path: routing.project_path || null,
        status: routing.snapshot ? routing.snapshot.status : null,
        reason_code: routing.snapshot ? routing.snapshot.reason_code : null
      },
      telemetry: { count: telemetry.length, limit }
    },
    request: {
      limit,
      shells: shellsMode,
      shell_limit: shellLimit,
      project_path: options.projectPath || null,
      workspace_id: options.workspaceId || null
    },
    endpoints: {
      telemetry: "/telemetry",
      telemetryStream: "/telemetry-stream",
      runtimeSnapshot: "/runtime-snapshot",
      routingSnapshot: "/routing-snapshot",
      routingDiagnostics: "/routing-diagnostics",
      agentBriefing: "/agent-briefing"
    }
  };
}

function readRequestBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", chunk => {
      body += chunk.toString("utf8");
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

const server = http.createServer(async (req, res) => {
  if (!req.url) {
    jsonResponse(res, 400, { ok: false, error: "missing url" });
    return;
  }

  if (req.method === "OPTIONS") {
    res.writeHead(204, {
      "Access-Control-Allow-Origin": "*",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
      "Access-Control-Allow-Headers": "Content-Type"
    });
    res.end();
    return;
  }

  if (req.url.startsWith("/telemetry-stream")) {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
      "Access-Control-Allow-Origin": "*"
    });
    res.write(": connected\n\n");
    telemetryClients.add(res);
    req.on("close", () => telemetryClients.delete(res));
    return;
  }

  if (req.url.startsWith("/telemetry") && req.method === "POST") {
    try {
      const body = await readRequestBody(req);
      const payload = body ? JSON.parse(body) : {};
      addTelemetryEvent(payload || {});
      jsonResponse(res, 200, { ok: true });
    } catch (error) {
      jsonResponse(res, 400, { ok: false, error: String(error) });
    }
    return;
  }

  if (req.url.startsWith("/telemetry")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const limit = parseBoundedPositiveInt(url.searchParams.get("limit"), 50, TELEMETRY_LIMIT);
    jsonResponse(res, 200, {
      ok: true,
      timestamp: new Date().toISOString(),
      events: telemetryEvents.slice(0, limit)
    });
    return;
  }

  if (req.url.startsWith("/routing-snapshot")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const { projectPath, workspaceId } = parseRoutingParams(url);
    if (!projectPath) {
      jsonResponse(res, 400, {
        ok: false,
        error: "project_path query param is required"
      });
      return;
    }

    const snapshot = await buildSnapshot({ projectPath, workspaceId, shellsMode: "all" });
    jsonResponse(res, 200, {
      ok: Boolean(snapshot && snapshot.ok),
      timestamp: new Date().toISOString(),
      project_path: projectPath,
      workspace_id: workspaceId || null,
      response: snapshot.routing?.snapshot || null,
      diagnostics: snapshot.routing?.diagnostics || null
    });
    return;
  }

  if (req.url.startsWith("/routing-diagnostics")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const { projectPath, workspaceId } = parseRoutingParams(url);

    const snapshot = await buildSnapshot({ projectPath, workspaceId, shellsMode: "all" });
    jsonResponse(res, 200, {
      ok: Boolean(snapshot && snapshot.ok),
      timestamp: new Date().toISOString(),
      project_path: projectPath || null,
      workspace_id: workspaceId || null,
      response: snapshot.routing?.diagnostics || null
    });
    return;
  }

  if (req.url.startsWith("/agent-briefing")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const limit = parseBoundedPositiveInt(url.searchParams.get("limit"), 200, TELEMETRY_LIMIT);
    const shellsParam = url.searchParams.get("shells");
    const shellsMode = shellsParam === "all" ? "all" : "recent";
    const shellLimit = parseBoundedPositiveInt(
      url.searchParams.get("shell_limit"),
      BRIEFING_SHELL_LIMIT,
      Number.MAX_SAFE_INTEGER
    );
    const projectPath = (url.searchParams.get("project_path") || "").trim() || undefined;
    const workspaceId = (url.searchParams.get("workspace_id") || "").trim() || undefined;
    const briefing = await buildBriefing({ limit, shellsMode, shellLimit, projectPath, workspaceId });
    jsonResponse(res, 200, briefing);
    return;
  }

  if (req.url.startsWith("/runtime-snapshot")) {
    const url = new URL(req.url, `http://localhost:${PORT}`);
    const shellsParam = url.searchParams.get("shells");
    const shellsMode = shellsParam === "all" ? "all" : "recent";
    const shellLimitParam = Number(url.searchParams.get("shell_limit"));
    const shellLimit = Number.isFinite(shellLimitParam) && shellLimitParam > 0
      ? shellLimitParam
      : BRIEFING_SHELL_LIMIT;
    const projectPath = (url.searchParams.get("project_path") || "").trim() || undefined;
    const workspaceId = (url.searchParams.get("workspace_id") || "").trim() || undefined;
    const snapshot = await buildSnapshot({ shellsMode, shellLimit, projectPath, workspaceId });
    jsonResponse(res, 200, snapshot);
    return;
  }

  jsonResponse(res, 200, {
    ok: true,
    endpoints: {
      telemetry: "/telemetry",
      telemetryStream: "/telemetry-stream",
      runtimeSnapshot: "/runtime-snapshot",
      routingSnapshot: "/routing-snapshot",
      routingDiagnostics: "/routing-diagnostics",
      agentBriefing: "/agent-briefing"
    },
    runtimeSource: "inspect /runtime-snapshot for live source metadata",
    artifactPath: RUNTIME_ARTIFACT_PATH,
    runtimeServiceConnectionPath: RUNTIME_SERVICE_CONNECTION_PATH
  });
});

server.listen(PORT, () => {
  console.log(`transparent-ui server listening on http://localhost:${PORT}`);
  console.log(`runtime artifact: ${RUNTIME_ARTIFACT_PATH}`);
  console.log(`runtime service connection: ${RUNTIME_SERVICE_CONNECTION_PATH}`);
});

setInterval(() => {
  telemetryClients.forEach(res => {
    try {
      res.write(": ping\n\n");
    } catch {
      telemetryClients.delete(res);
    }
  });
}, 15000);

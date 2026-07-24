import {
  ValidationError,
  isAttentionLabel,
  isUUID,
  maximumRequestBytes,
  parseBundle,
  parseObservationUpload,
  type ObservationRecord,
} from "./domain";

const apiHeaders = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

function json(value: unknown, status = 200): Response {
  return new Response(JSON.stringify(value), { status, headers: apiHeaders });
}

async function authorized(request: Request, env: Env): Promise<boolean> {
  const authorization = request.headers.get("Authorization");
  const supplied = authorization?.startsWith("Bearer ") ? authorization.slice(7) : "";
  const encoder = new TextEncoder();
  const [suppliedHash, expectedHash] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(supplied)),
    crypto.subtle.digest("SHA-256", encoder.encode(env.DASHBOARD_TOKEN)),
  ]);
  return crypto.subtle.timingSafeEqual(suppliedHash, expectedHash);
}

async function requestJSON(request: Request): Promise<unknown> {
  const contentLength = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > maximumRequestBytes) {
    throw new ValidationError(`request exceeds ${maximumRequestBytes} bytes`);
  }
  const contentType = request.headers.get("Content-Type") ?? "";
  if (!contentType.toLowerCase().startsWith("application/json")) {
    throw new ValidationError("Content-Type must be application/json");
  }
  if (request.body === null) throw new ValidationError("request body is required");

  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let totalBytes = 0;
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    totalBytes += chunk.value.byteLength;
    if (totalBytes > maximumRequestBytes) {
      await reader.cancel();
      throw new ValidationError(`request exceeds ${maximumRequestBytes} bytes`);
    }
    chunks.push(chunk.value);
  }

  const body = new Uint8Array(totalBytes);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return JSON.parse(new TextDecoder().decode(body));
}

async function registerBundle(request: Request, env: Env): Promise<Response> {
  const bundle = parseBundle(await requestJSON(request));
  await env.DB.prepare(
    `INSERT OR IGNORE INTO bundles
      (id, source_host, source_created_at, expected_observations)
     VALUES (?1, ?2, ?3, ?4)`,
  ).bind(bundle.id, bundle.sourceHost, bundle.createdAt, bundle.expectedObservations).run();

  const stored = await env.DB.prepare(
    `SELECT source_host, source_created_at, expected_observations
       FROM bundles WHERE id = ?1`,
  ).bind(bundle.id).first<{
    source_host: string | null;
    source_created_at: string;
    expected_observations: number;
  }>();

  if (
    stored === null
    || stored.source_host !== bundle.sourceHost
    || stored.source_created_at !== bundle.createdAt
    || stored.expected_observations !== bundle.expectedObservations
  ) {
    return json({ error: "bundle id is already registered with different metadata" }, 409);
  }
  return json({ bundleID: bundle.id, expectedObservations: bundle.expectedObservations }, 201);
}

function observationStatements(env: Env, bundleID: string, observation: ObservationRecord): D1PreparedStatement[] {
  const insert = env.DB.prepare(
    `INSERT OR IGNORE INTO observations (
       id, first_bundle_id, recorded_at, event, label, harness, session_id,
       run_id, scenario_id, checkpoint, columns_count, rows_count, grid_json,
       activity_state, activity_evidence, payload_json
     ) VALUES (
       ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16
     )`,
  ).bind(
    observation.id,
    bundleID,
    observation.recordedAt,
    observation.event,
    observation.label,
    observation.harness,
    observation.sessionID,
    observation.runID,
    observation.scenarioID,
    observation.checkpoint,
    observation.columns,
    observation.rows,
    observation.gridJSON,
    observation.activityState,
    observation.activityEvidence,
    observation.payloadJSON,
  );
  const source = env.DB.prepare(
    `INSERT OR IGNORE INTO observation_sources (observation_id, bundle_id)
     SELECT ?1, ?2 WHERE EXISTS (SELECT 1 FROM observations WHERE id = ?1)`,
  ).bind(observation.id, bundleID);
  return [insert, source];
}

async function uploadObservations(request: Request, env: Env, bundleID: string): Promise<Response> {
  if (!isUUID(bundleID)) return json({ error: "invalid bundle id" }, 400);
  const bundleExists = await env.DB.prepare(
    "SELECT 1 AS present FROM bundles WHERE id = ?1",
  ).bind(bundleID).first("present");
  if (bundleExists === null) return json({ error: "bundle is not registered" }, 404);

  const observations = parseObservationUpload(await requestJSON(request));
  const statements = observations.flatMap((observation) => observationStatements(env, bundleID, observation));
  const results = await env.DB.batch(statements);
  const inserted = results
    .filter((_, index) => index % 2 === 0)
    .reduce((total, result) => total + Number(result.meta.changes ?? 0), 0);

  return json({ accepted: observations.length, inserted, duplicates: observations.length - inserted }, 202);
}

type AggregateRow = { kind: string; name: string; count: number };
type BundleRow = {
  id: string;
  sourceHost: string | null;
  createdAt: string;
  importedAt: string;
  expected: number;
  received: number;
};
type ObservationRow = {
  id: string;
  recordedAt: string;
  event: string;
  label: string | null;
  confidence: number | null;
  rationale: string | null;
  provenance: string | null;
  harness: string | null;
  sessionID: string;
  runID: string | null;
  scenarioID: string | null;
  checkpoint: string | null;
  columns: number;
  rows: number;
  gridJSON: string;
  activityState: string;
  activityEvidence: string;
};

function storedGrid(value: string): string[] {
  const parsed: unknown = JSON.parse(value);
  if (!Array.isArray(parsed)) return [];
  const lines: string[] = [];
  for (const line of parsed) {
    if (typeof line !== "string") return [];
    lines.push(line);
  }
  return lines;
}

async function dashboard(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const parsedLimit = Number(url.searchParams.get("limit") ?? "12");
  const parsedOffset = Number(url.searchParams.get("offset") ?? "0");
  const limit = Number.isInteger(parsedLimit) ? Math.min(Math.max(parsedLimit, 1), 50) : 12;
  const offset = Number.isInteger(parsedOffset) ? Math.min(Math.max(parsedOffset, 0), 100_000) : 0;
  const label = url.searchParams.get("label")?.trim() ?? "";
  const harness = url.searchParams.get("harness")?.trim() ?? "";

  const conditions: string[] = [];
  const parameters: (string | number | null)[] = [];
  if (label === "labeled") {
    conditions.push("label IS NOT NULL");
  } else if (label === "unlabeled") {
    conditions.push("label IS NULL");
  } else if (label.length > 0) {
    if (!isAttentionLabel(label)) return json({ error: "invalid label filter" }, 400);
    conditions.push(`label = ?${parameters.length + 1}`);
    parameters.push(label);
  }
  if (harness.length > 0) {
    if (harness.length > 160) return json({ error: "invalid harness filter" }, 400);
    conditions.push(`harness = ?${parameters.length + 1}`);
    parameters.push(harness);
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
  parameters.push(limit, offset);
  const limitParameter = parameters.length - 1;
  const offsetParameter = parameters.length;

  const aggregateQuery = env.DB.prepare(
    `SELECT 'total' AS kind, 'all' AS name, COUNT(*) AS count FROM observations
     UNION ALL
     SELECT 'labeled', 'all', COUNT(*) FROM observations WHERE label IS NOT NULL
     UNION ALL
     SELECT 'label', COALESCE(label, 'unlabeled'), COUNT(*) FROM observations GROUP BY label
     UNION ALL
     SELECT 'harness', COALESCE(harness, 'unknown'), COUNT(*) FROM observations GROUP BY harness
     UNION ALL
     SELECT 'session', 'all', COUNT(DISTINCT session_id) FROM observations`,
  ).all<AggregateRow>();
  const bundleQuery = env.DB.prepare(
    `SELECT b.id, b.source_host AS sourceHost, b.source_created_at AS createdAt,
            b.imported_at AS importedAt, b.expected_observations AS expected,
            COUNT(s.observation_id) AS received
       FROM bundles b
       LEFT JOIN observation_sources s ON s.bundle_id = b.id
      GROUP BY b.id
      ORDER BY b.imported_at DESC
      LIMIT 20`,
  ).all<BundleRow>();
  const observationsQuery = env.DB.prepare(
    `SELECT id, recorded_at AS recordedAt, event, label,
            json_extract(payload_json, '$.annotation.confidence') AS confidence,
            json_extract(payload_json, '$.annotation.rationale') AS rationale,
            json_extract(payload_json, '$.annotation.provenance') AS provenance,
            harness,
            session_id AS sessionID, run_id AS runID, scenario_id AS scenarioID,
            checkpoint, columns_count AS columns, rows_count AS rows,
            grid_json AS gridJSON, activity_state AS activityState,
            activity_evidence AS activityEvidence
       FROM observations ${where}
      ORDER BY recorded_at DESC
      LIMIT ?${limitParameter} OFFSET ?${offsetParameter}`,
  ).bind(...parameters).all<ObservationRow>();

  const [aggregates, bundles, observations] = await Promise.all([
    aggregateQuery,
    bundleQuery,
    observationsQuery,
  ]);
  return json({
    aggregates: aggregates.results,
    bundles: bundles.results,
    observations: observations.results.map((observation) => ({
      ...observation,
      grid: storedGrid(observation.gridJSON),
      gridJSON: undefined,
    })),
    pagination: { limit, offset, returned: observations.results.length },
  });
}

async function observationDetail(env: Env, id: string): Promise<Response> {
  if (!isUUID(id)) return json({ error: "invalid observation id" }, 400);
  const result = await env.DB.prepare(
    "SELECT payload_json AS payload FROM observations WHERE id = ?1",
  ).bind(id).first<{ payload: string }>();
  if (result === null) return json({ error: "observation not found" }, 404);
  return new Response(result.payload, { headers: apiHeaders });
}

async function routeAPI(request: Request, env: Env): Promise<Response> {
  if (!(await authorized(request, env))) {
    return json({ error: "unauthorized" }, 401);
  }

  const url = new URL(request.url);
  if (request.method === "GET" && url.pathname === "/api/dashboard") {
    return dashboard(request, env);
  }
  if (request.method === "POST" && url.pathname === "/api/bundles") {
    return registerBundle(request, env);
  }
  const uploadMatch = url.pathname.match(/^\/api\/bundles\/([^/]+)\/observations$/);
  if (request.method === "POST" && uploadMatch !== null) {
    return uploadObservations(request, env, decodeURIComponent(uploadMatch[1]));
  }
  const detailMatch = url.pathname.match(/^\/api\/observations\/([^/]+)$/);
  if (request.method === "GET" && detailMatch !== null) {
    return observationDetail(env, decodeURIComponent(detailMatch[1]));
  }
  return json({ error: "not found" }, 404);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    try {
      if (url.pathname.startsWith("/api/")) return await routeAPI(request, env);
      return await env.ASSETS.fetch(request);
    } catch (error) {
      if (error instanceof ValidationError || error instanceof SyntaxError) {
        return json({ error: error.message }, 400);
      }
      console.error(JSON.stringify({
        message: "unhandled request error",
        error: error instanceof Error ? error.message : String(error),
        method: request.method,
        path: url.pathname,
      }));
      return json({ error: "internal server error" }, 500);
    }
  },
} satisfies ExportedHandler<Env>;

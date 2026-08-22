import {
  ValidationError,
  isAttentionLabel,
  isUUID,
  maximumRequestBytes,
  parseBundle,
  parseObservationUpload,
  parseReview,
  type ObservationRecord,
  type ReviewInput,
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
  const humanCorrectionReview = env.DB.prepare(
    `INSERT OR IGNORE INTO observation_reviews
       (observation_id, status, label, reason, review_source)
     SELECT ?1, 'accepted', ?2, ?3, 'human'
      WHERE ?2 IS NOT NULL
        AND EXISTS (
          SELECT 1 FROM observations
           WHERE id = ?1
             AND label = ?2
             AND json_extract(payload_json, '$.annotation.provenance')
                   = 'cherry_in_app_human_correction'
             AND (
               (?2 = 'unknown' AND ?3 IS NULL)
               OR json_extract(payload_json, '$.annotation.reason') = ?3
               OR (
                 ?2 = 'no_attention_needed'
                 AND ?3 IS NULL
                 AND json_extract(payload_json, '$.annotation.reason') IS NULL
               )
             )
        )`,
  ).bind(
    observation.id,
    observation.humanCorrectionLabel,
    observation.humanCorrectionReason,
  );
  return [insert, source, humanCorrectionReview];
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
    .filter((_, index) => index % 3 === 0)
    .reduce((total, result) => total + Number(result.meta.changes ?? 0), 0);

  return json({ accepted: observations.length, inserted, duplicates: observations.length - inserted }, 202);
}

type AggregateRow = { kind: string; name: string; count: number };
type CountRow = { count: number };
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
  reason: string | null;
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
  reviewStatus: string | null;
  reviewLabel: string | null;
  reviewReason: string | null;
  reviewSource: string | null;
  reviewedAt: string | null;
};
type StoredObservationLabel = { label: string | null; payload: string };
type ReviewRow = {
  status: string;
  label: string | null;
  reason: string | null;
  source: string;
  reviewedAt: string;
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

function normalizedLabel(label: string | null): string | null {
  if (label === "approval_required" || label === "waiting_for_input" || label === "ready_for_review") {
    return "attention_needed";
  }
  return label;
}

function normalizedReason(label: string | null, payload: string): string | null {
  const parsed: unknown = JSON.parse(payload);
  if (typeof parsed === "object" && parsed !== null && !Array.isArray(parsed)) {
    const annotation = "annotation" in parsed ? parsed.annotation : null;
    if (typeof annotation === "object" && annotation !== null && !Array.isArray(annotation)) {
      const reason = "reason" in annotation ? annotation.reason : null;
      if (typeof reason === "string") return reason;
    }
  }
  if (label === "approval_required") return "waiting_for_approval";
  if (label === "waiting_for_input") return "waiting_for_input";
  if (label === "ready_for_review") return "result_ready";
  return null;
}

async function dashboard(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const parsedLimit = Number(url.searchParams.get("limit") ?? "12");
  const parsedOffset = Number(url.searchParams.get("offset") ?? "0");
  const limit = Number.isInteger(parsedLimit) ? Math.min(Math.max(parsedLimit, 1), 50) : 12;
  const offset = Number.isInteger(parsedOffset) ? Math.min(Math.max(parsedOffset, 0), 100_000) : 0;
  const label = url.searchParams.get("label")?.trim() ?? "";
  const harness = url.searchParams.get("harness")?.trim() ?? "";
  const review = url.searchParams.get("review")?.trim() ?? "";

  const conditions: string[] = [];
  const parameters: (string | number | null)[] = [];
  if (label === "labeled") {
    conditions.push("o.label IS NOT NULL");
  } else if (label === "unlabeled") {
    conditions.push("o.label IS NULL");
  } else if (label === "attention_needed") {
    const placeholders = ["attention_needed", "approval_required", "waiting_for_input", "ready_for_review"]
      .map((value) => {
        parameters.push(value);
        return `?${parameters.length}`;
      });
    conditions.push(`o.label IN (${placeholders.join(", ")})`);
  } else if (label.length > 0) {
    if (!isAttentionLabel(label)) return json({ error: "invalid label filter" }, 400);
    conditions.push(`o.label = ?${parameters.length + 1}`);
    parameters.push(label);
  }
  if (harness.length > 0) {
    if (harness.length > 160) return json({ error: "invalid harness filter" }, 400);
    conditions.push(`o.harness = ?${parameters.length + 1}`);
    parameters.push(harness);
  }
  if (review === "pending") {
    conditions.push("o.label IS NOT NULL AND r.observation_id IS NULL");
  } else if (review === "reviewed") {
    conditions.push("r.status IN ('accepted', 'corrected')");
  } else if (review === "accepted" || review === "corrected" || review === "skipped") {
    conditions.push(`r.status = ?${parameters.length + 1}`);
    parameters.push(review);
  } else if (review.length > 0 && review !== "all") {
    return json({ error: "invalid review filter" }, 400);
  }
  const where = conditions.length > 0 ? `WHERE ${conditions.join(" AND ")}` : "";
  const filterParameters = [...parameters];
  parameters.push(limit, offset);
  const limitParameter = parameters.length - 1;
  const offsetParameter = parameters.length;

  const aggregateQuery = env.DB.prepare(
    `SELECT 'total' AS kind, 'all' AS name, COUNT(*) AS count FROM observations
     UNION ALL
     SELECT 'labeled', 'all', COUNT(*) FROM observations WHERE label IS NOT NULL
     UNION ALL
     SELECT 'label',
            CASE
              WHEN label IN ('approval_required', 'waiting_for_input', 'ready_for_review')
                THEN 'attention_needed'
              ELSE COALESCE(label, 'unlabeled')
            END,
            COUNT(*)
       FROM observations
      GROUP BY CASE
        WHEN label IN ('approval_required', 'waiting_for_input', 'ready_for_review')
          THEN 'attention_needed'
        ELSE COALESCE(label, 'unlabeled')
      END
     UNION ALL
     SELECT 'harness', COALESCE(harness, 'unknown'), COUNT(*) FROM observations GROUP BY harness
     UNION ALL
     SELECT 'session', 'all', COUNT(DISTINCT session_id) FROM observations`,
  ).all<AggregateRow>();
  const reviewAggregateQuery = env.DB.prepare(
    `SELECT 'review' AS kind, 'pending' AS name, COUNT(*) AS count
       FROM observations o
       LEFT JOIN observation_reviews r ON r.observation_id = o.id
      WHERE o.label IS NOT NULL AND r.observation_id IS NULL
     UNION ALL
     SELECT 'review', 'reviewed', COUNT(*)
       FROM observation_reviews
      WHERE status IN ('accepted', 'corrected')
     UNION ALL
     SELECT 'review', status, COUNT(*) FROM observation_reviews GROUP BY status`,
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
    `SELECT o.id, o.recorded_at AS recordedAt, o.event,
            CASE
              WHEN o.label IN ('approval_required', 'waiting_for_input', 'ready_for_review')
                THEN 'attention_needed'
              ELSE o.label
            END AS label,
            COALESCE(
              json_extract(o.payload_json, '$.annotation.reason'),
              CASE o.label
                WHEN 'approval_required' THEN 'waiting_for_approval'
                WHEN 'waiting_for_input' THEN 'waiting_for_input'
                WHEN 'ready_for_review' THEN 'result_ready'
                ELSE NULL
              END
            ) AS reason,
            json_extract(o.payload_json, '$.annotation.confidence') AS confidence,
            json_extract(o.payload_json, '$.annotation.rationale') AS rationale,
            json_extract(o.payload_json, '$.annotation.provenance') AS provenance,
            o.harness,
            o.session_id AS sessionID, o.run_id AS runID, o.scenario_id AS scenarioID,
            o.checkpoint, o.columns_count AS columns, o.rows_count AS rows,
            o.grid_json AS gridJSON, o.activity_state AS activityState,
            o.activity_evidence AS activityEvidence,
            r.status AS reviewStatus, r.label AS reviewLabel, r.reason AS reviewReason,
            r.review_source AS reviewSource,
            r.reviewed_at AS reviewedAt
       FROM observations o
       LEFT JOIN observation_reviews r ON r.observation_id = o.id
       ${where}
      ORDER BY o.recorded_at DESC
      LIMIT ?${limitParameter} OFFSET ?${offsetParameter}`,
  ).bind(...parameters).all<ObservationRow>();
  const filteredCountQuery = env.DB.prepare(
    `SELECT COUNT(*) AS count
       FROM observations o
       LEFT JOIN observation_reviews r ON r.observation_id = o.id
       ${where}`,
  ).bind(...filterParameters).first<CountRow>();

  const [aggregates, reviewAggregates, bundles, observations, filteredCount] = await Promise.all([
    aggregateQuery,
    reviewAggregateQuery,
    bundleQuery,
    observationsQuery,
    filteredCountQuery,
  ]);
  return json({
    aggregates: [...aggregates.results, ...reviewAggregates.results],
    bundles: bundles.results,
    observations: observations.results.map((observation) => ({
      ...observation,
      grid: storedGrid(observation.gridJSON),
      gridJSON: undefined,
    })),
    pagination: {
      limit,
      offset,
      returned: observations.results.length,
      total: filteredCount?.count ?? 0,
    },
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

async function reviewObservation(request: Request, env: Env, id: string): Promise<Response> {
  if (!isUUID(id)) return json({ error: "invalid observation id" }, 400);
  const input: ReviewInput = parseReview(await requestJSON(request));
  const stored = await env.DB.prepare(
    "SELECT label, payload_json AS payload FROM observations WHERE id = ?1",
  ).bind(id).first<StoredObservationLabel>();
  if (stored === null) return json({ error: "observation not found" }, 404);

  let status: "accepted" | "corrected" | "skipped";
  let label: string | null;
  let reason: string | null;
  if (input.action === "skip") {
    status = "skipped";
    label = null;
    reason = null;
  } else if (input.action === "correct") {
    status = "corrected";
    label = input.label;
    reason = input.reason;
  } else {
    status = "accepted";
    label = normalizedLabel(stored.label);
    reason = normalizedReason(stored.label, stored.payload);
    if (label === null) return json({ error: "unlabeled observations cannot be accepted" }, 409);
    if (label === "attention_needed" && reason === null) {
      return json({ error: "action-needed labels need a reason before they can be accepted" }, 409);
    }
    if (label === "unknown") reason = null;
  }

  await env.DB.prepare(
    `INSERT INTO observation_reviews (observation_id, status, label, reason, review_source)
     VALUES (?1, ?2, ?3, ?4, 'human')
     ON CONFLICT(observation_id) DO UPDATE SET
       status = excluded.status,
       label = excluded.label,
       reason = excluded.reason,
       review_source = excluded.review_source,
       reviewed_at = CURRENT_TIMESTAMP`,
  ).bind(id, status, label, reason).run();
  const review = await env.DB.prepare(
    `SELECT status, label, reason, review_source AS source, reviewed_at AS reviewedAt
       FROM observation_reviews WHERE observation_id = ?1`,
  ).bind(id).first<ReviewRow>();
  if (review === null) throw new Error("review was not stored");
  return json({ observationID: id, review });
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
  const reviewMatch = url.pathname.match(/^\/api\/observations\/([^/]+)\/review$/);
  if (request.method === "PUT" && reviewMatch !== null) {
    return reviewObservation(request, env, decodeURIComponent(reviewMatch[1]));
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

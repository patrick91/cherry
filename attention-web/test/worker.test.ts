import { SELF, env } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";

const authorization = { Authorization: "Bearer test-dashboard-token" };
const bundleID = "32b00665-797d-4800-9030-6171a6d9e9df";
const observationID = "6594bade-c891-42cb-8cb1-e51c16f1ab95";

const bundle = {
  bundleSchemaVersion: 1,
  observationSchemaVersion: 1,
  bundleID,
  createdAt: "2026-07-22T12:00:00Z",
  sourceHost: "test-laptop",
  files: [],
  totals: { files: 1, bytes: 800, observations: 1, labeled: 1 },
};

const observation = {
  schemaVersion: 1,
  id: observationID,
  recordedAt: "2026-07-22T12:00:01Z",
  event: "labeled_checkpoint",
  label: "attention_needed",
  scenarioID: "waiting-for-approval",
  checkpoint: "human_verified",
  session: {
    id: "4c5d7267-f12c-4e8d-a821-65b9f8bf848c",
    kind: "agent",
    harness: "Codex",
    harnessVersion: "fixture 1.0",
    runID: "run-1",
  },
  terminal: {
    columns: 100,
    rows: 32,
    usesAlternateScreen: false,
    cursor: { row: 4, column: 2, shape: "block", isVisible: true },
    grid: ["Allow this command?", "1. Yes  2. No"],
    styledGrid: [
      [{
        text: "Allow this command?",
        foreground: { space: "palette256", components: [82] },
        background: null,
        attributes: ["bold"],
      }],
      [{
        text: "1. Yes  2. No",
        foreground: { space: "rgb", components: [239, 91, 114] },
        background: null,
        attributes: [],
      }],
    ],
    scrollbackLinesOmitted: 4,
  },
  timing: {
    millisecondsSinceStarted: 4_000,
    millisecondsSinceLastOutput: 120,
    millisecondsSinceLastContentChange: 120,
    millisecondsSinceLastHumanInput: 2_000,
  },
  activity: {
    state: "idle",
    evidence: "quiet_window",
    hasUnreadNotification: false,
    processState: "Running",
  },
  interaction: {
    hasUnsubmittedInput: true,
    millisecondsSinceLastKeystroke: 850,
    terminalFocused: false,
  },
  annotation: {
    schemaVersion: 1,
    provenance: "human_review",
    confidence: 0.94,
    rationale: "approval_prompt_visible",
    reason: "waiting_for_approval",
  },
  outputVersion: 4,
  contentVersion: 3,
};

async function api(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", authorization.Authorization);
  if (init.body !== undefined) headers.set("Content-Type", "application/json");
  return SELF.fetch(`https://attention.test${path}`, { ...init, headers });
}

beforeEach(async () => {
  await env.DB.batch([
    env.DB.prepare("DELETE FROM observation_reviews"),
    env.DB.prepare("DELETE FROM observation_sources"),
    env.DB.prepare("DELETE FROM observations"),
    env.DB.prepare("DELETE FROM bundles"),
  ]);
});

describe("attention dashboard Worker", () => {
  it("rejects requests without the dashboard token", async () => {
    const response = await SELF.fetch("https://attention.test/api/dashboard");
    expect(response.status).toBe(401);
    await expect(response.json()).resolves.toEqual({ error: "unauthorized" });
  });

  it("stores, deduplicates, lists, and retrieves observations", async () => {
    const registration = await api("/api/bundles", {
      method: "POST",
      body: JSON.stringify(bundle),
    });
    expect(registration.status).toBe(201);

    const firstUpload = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [observation] }),
    });
    expect(firstUpload.status).toBe(202);
    await expect(firstUpload.json()).resolves.toMatchObject({ inserted: 1, duplicates: 0 });

    const duplicateUpload = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [observation] }),
    });
    await expect(duplicateUpload.json()).resolves.toMatchObject({ inserted: 0, duplicates: 1 });

    const dashboard = await api("/api/dashboard?label=attention_needed&harness=Codex");
    expect(dashboard.status).toBe(200);
    const dashboardText = await dashboard.text();
    expect(dashboardText).toContain('"kind":"total","name":"all","count":1');
    expect(dashboardText).toContain('"pagination":{"limit":12,"offset":0,"returned":1,"total":1}');
    expect(dashboardText).toContain('"id":"6594bade-c891-42cb-8cb1-e51c16f1ab95"');
    expect(dashboardText).toContain('"grid":["Allow this command?","1. Yes  2. No"]');
    expect(dashboardText).toContain('"confidence":0.94');
    expect(dashboardText).toContain('"rationale":"approval_prompt_visible"');
    expect(dashboardText).toContain('"reason":"waiting_for_approval"');

    const labeledDashboard = await api("/api/dashboard?label=labeled");
    expect(labeledDashboard.status).toBe(200);
    await expect(labeledDashboard.text()).resolves.toContain(observationID);

    const detail = await api(`/api/observations/${observationID}`);
    expect(detail.status).toBe(200);
    const detailText = await detail.text();
    expect(detailText).toContain('"attention_needed"');
    expect(detailText).toContain('"space":"palette256","components":[82]');
    expect(detailText).toContain('"hasUnsubmittedInput":true');
  });

  it("normalizes legacy attention labels into the binary taxonomy", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    const legacy = {
      ...structuredClone(observation),
      id: "5cd5c9dc-2734-4447-837e-e1060831d16c",
      label: "ready_for_review",
      annotation: {
        schemaVersion: 1,
        provenance: "human_review",
        confidence: 0.94,
        rationale: "completed_turn_at_prompt",
      },
    };
    const upload = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [legacy] }),
    });
    expect(upload.status).toBe(202);

    const dashboard = await api("/api/dashboard?label=attention_needed");
    expect(dashboard.status).toBe(200);
    const dashboardText = await dashboard.text();
    expect(dashboardText).toContain('"label":"attention_needed"');
    expect(dashboardText).toContain('"reason":"result_ready"');
    expect(dashboardText).toContain('"kind":"label","name":"attention_needed","count":1');
  });

  it("stores an accepted human review and removes it from the pending queue", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [observation] }),
    });

    const pendingBefore = await responseText("/api/dashboard?label=labeled&review=pending");
    expect(pendingBefore).toContain(`"id":"${observationID}"`);
    expect(pendingBefore).toContain('"kind":"review","name":"pending","count":1');

    const accepted = await api(`/api/observations/${observationID}/review`, {
      method: "PUT",
      body: JSON.stringify({ action: "accept" }),
    });
    expect(accepted.status).toBe(200);
    await expect(accepted.json()).resolves.toMatchObject({
      observationID,
      review: {
        status: "accepted",
        label: "attention_needed",
        reason: "waiting_for_approval",
      },
    });

    const pendingAfter = await responseText("/api/dashboard?label=labeled&review=pending");
    expect(pendingAfter).not.toContain(`"id":"${observationID}"`);
    const reviewed = await responseText("/api/dashboard?review=reviewed");
    expect(reviewed).toContain('"reviewStatus":"accepted"');
    expect(reviewed).toContain('"reviewLabel":"attention_needed"');
    expect(reviewed).toContain('"reviewReason":"waiting_for_approval"');
  });

  it("stores corrections and skipped reviews", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [observation] }),
    });

    const corrected = await api(`/api/observations/${observationID}/review`, {
      method: "PUT",
      body: JSON.stringify({ action: "correct", label: "no_attention_needed", reason: null }),
    });
    expect(corrected.status).toBe(200);
    await expect(corrected.json()).resolves.toMatchObject({
      review: { status: "corrected", label: "no_attention_needed", reason: null },
    });

    const skipped = await api(`/api/observations/${observationID}/review`, {
      method: "PUT",
      body: JSON.stringify({ action: "skip" }),
    });
    expect(skipped.status).toBe(200);
    await expect(skipped.json()).resolves.toMatchObject({
      review: { status: "skipped", label: null, reason: null },
    });
    const dashboard = await responseText("/api/dashboard?review=skipped");
    expect(dashboard).toContain('"reviewStatus":"skipped"');
  });

  it("validates human review labels and reasons", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [observation] }),
    });

    const response = await api(`/api/observations/${observationID}/review`, {
      method: "PUT",
      body: JSON.stringify({ action: "correct", label: "attention_needed", reason: null }),
    });
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "review.reason is required for attention_needed",
    });
  });

  it("rejects invalid labels before writing", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    const invalid = { ...observation, id: "5cd5c9dc-2734-4447-837e-e1060831d16c", label: "looks_busy" };
    const response = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [invalid] }),
    });
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({ error: "unsupported observation label: looks_busy" });
  });

  it("rejects invalid terminal colors before writing", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    const invalid = structuredClone(observation);
    invalid.id = "5cd5c9dc-2734-4447-837e-e1060831d16c";
    invalid.terminal.styledGrid[0][0].foreground.components = [999];
    const response = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [invalid] }),
    });
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "observation.terminal.styledGrid[0][0].foreground.components[0] must be an integer from 0 to 255",
    });
  });

  it("rejects invalid interaction signals before writing", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    const invalid = structuredClone(observation);
    invalid.id = "5cd5c9dc-2734-4447-837e-e1060831d16c";
    invalid.interaction.hasUnsubmittedInput = "yes" as unknown as boolean;
    const response = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [invalid] }),
    });
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "observation.interaction.hasUnsubmittedInput must be a boolean",
    });
  });

  it("rejects invalid attention reasons before writing", async () => {
    await api("/api/bundles", { method: "POST", body: JSON.stringify(bundle) });
    const invalid = structuredClone(observation);
    invalid.id = "5cd5c9dc-2734-4447-837e-e1060831d16c";
    invalid.annotation.reason = "look_over_here";
    const response = await api(`/api/bundles/${bundleID}/observations`, {
      method: "POST",
      body: JSON.stringify({ observations: [invalid] }),
    });
    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toEqual({
      error: "unsupported observation attention reason: look_over_here",
    });
  });
});

async function responseText(path: string): Promise<string> {
  const response = await api(path);
  expect(response.status).toBe(200);
  return response.text();
}

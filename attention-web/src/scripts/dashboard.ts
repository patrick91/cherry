type ManifestEntry = {
  relativePath: string;
  observationCount: number;
};

type StudyManifest = {
  bundleSchemaVersion: number;
  observationSchemaVersion: number;
  bundleID: string;
  createdAt: string;
  sourceHost?: string;
  files: ManifestEntry[];
  totals: { observations: number };
};

type Aggregate = { kind: string; name: string; count: number };
type ObservationSummary = {
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
  grid: string[];
  activityState: string;
  activityEvidence: string;
};
type BundleSummary = {
  id: string;
  sourceHost: string | null;
  createdAt: string;
  importedAt: string;
  expected: number;
  received: number;
};
type DashboardResponse = {
  aggregates: Aggregate[];
  bundles: BundleSummary[];
  observations: ObservationSummary[];
  pagination: { limit: number; offset: number; returned: number };
};

const tokenKey = "cherry-attention-dashboard-token";
const pageSize = 12;
let token = sessionStorage.getItem(tokenKey) ?? "";
let selectedFiles: File[] = [];
let pageOffset = 0;
let activeObservationID: string | null = null;
let detailRequest = 0;

type LabelInformation = {
  name: string;
  description: string;
};

const labelInformation: Record<string, LabelInformation> = {
  approval_required: {
    name: "Approval required",
    description: "The agent is blocked until you approve or reject an action.",
  },
  waiting_for_input: {
    name: "Waiting for input",
    description: "The agent asked a question or needs information from you before it can continue.",
  },
  ready_for_review: {
    name: "Ready for review",
    description: "The agent completed its turn and returned to the prompt. Its result is ready to read.",
  },
  no_attention_needed: {
    name: "No attention needed",
    description: "The agent was still working, so there was nothing for you to do at that moment.",
  },
  unknown: {
    name: "Unknown",
    description: "The captured state was ambiguous or interrupted and needs a human judgment.",
  },
  labeled: {
    name: "All provisional labels",
    description: "Review the observations Codex labeled from terminal content. These are candidates for human verification.",
  },
  unlabeled: {
    name: "Unlabeled",
    description: "No attention label has been assigned to this observation.",
  },
};

const rationaleDescriptions: Record<string, string> = {
  active_working_indicator: "The terminal showed an active working indicator.",
  ambiguous_post_resume_prompt: "The prompt appeared after a resume, but the next expected action was unclear.",
  completed_turn_at_prompt: "The agent completed its turn and returned to an idle prompt.",
  explicit_confirmation_request: "The terminal contained an explicit request for confirmation.",
  interrupted_conversation: "The conversation was interrupted before reaching a normal completion.",
  resume_picker_ui: "A session-resume picker was visible and needed a human choice.",
  startup_authentication_error: "The harness reported an authentication problem during startup.",
};

function element<T extends HTMLElement>(id: string): T {
  const value = document.getElementById(id);
  if (value === null) throw new Error(`Missing element #${id}`);
  return value as T;
}

const loginView = element<HTMLElement>("login-view");
const dashboardView = element<HTMLElement>("dashboard");
const loginForm = element<HTMLFormElement>("login-form");
const tokenInput = element<HTMLInputElement>("token");
const loginMessage = element<HTMLElement>("login-message");
const connectionState = element<HTMLElement>("connection-state");
const bundleInput = element<HTMLInputElement>("bundle-input");
bundleInput.setAttribute("webkitdirectory", "");
const uploadButton = element<HTMLButtonElement>("upload-button");
const uploadStatus = element<HTMLElement>("upload-status");
const labelFilter = element<HTMLSelectElement>("label-filter");
const harnessFilter = element<HTMLSelectElement>("harness-filter");
const previousPage = element<HTMLButtonElement>("previous-page");
const nextPage = element<HTMLButtonElement>("next-page");

function showLogin(message = ""): void {
  dashboardView.hidden = true;
  loginView.hidden = false;
  connectionState.textContent = "Locked";
  delete connectionState.dataset.connected;
  loginMessage.textContent = message;
  loginMessage.dataset.error = message.length > 0 ? "true" : "false";
  tokenInput.value = "";
  tokenInput.focus();
}

function showDashboard(): void {
  loginView.hidden = true;
  dashboardView.hidden = false;
  connectionState.textContent = "Connected";
  connectionState.dataset.connected = "true";
}

async function api(path: string, init: RequestInit = {}): Promise<Response> {
  const headers = new Headers(init.headers);
  headers.set("Authorization", `Bearer ${token}`);
  if (init.body !== undefined) headers.set("Content-Type", "application/json");
  const response = await fetch(path, { ...init, headers });
  if (response.status === 401) {
    sessionStorage.removeItem(tokenKey);
    token = "";
    showLogin("That token was not accepted.");
    throw new Error("Unauthorized");
  }
  return response;
}

async function responseJSON<T>(response: Response): Promise<T> {
  const value: unknown = await response.json();
  if (!response.ok) {
    const message =
      typeof value === "object"
      && value !== null
      && "error" in value
      && typeof value.error === "string"
        ? value.error
        : `Request failed with status ${response.status}`;
    throw new Error(message);
  }
  return value as T;
}

function count(aggregates: Aggregate[], kind: string, name: string): number {
  return aggregates.find((entry) => entry.kind === kind && entry.name === name)?.count ?? 0;
}

function formatLabel(value: string | null): string {
  return labelInformation[value ?? "unlabeled"]?.name ?? formatIdentifier(value ?? "unlabeled");
}

function formatIdentifier(value: string): string {
  return value.replaceAll("_", " ").replace(/^./, (character) => character.toUpperCase());
}

function formatDate(value: string): string {
  const date = new Date(value);
  return Number.isFinite(date.getTime())
    ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date)
    : value;
}

function summarizeTerminal(grid: string[]): string {
  const candidates = grid
    .map((line) => line.trim())
    .filter((line) => {
      if (line.length < 3) return false;
      if (/^[─━═_\-=\s]+$/.test(line)) return false;
      if (/^[›❯]\s/.test(line)) return false;
      if (/^(•\s+)?Working \(/i.test(line)) return false;
      if (/Worked for \d/i.test(line)) return false;
      if (/^\d+$/.test(line)) return false;
      if (/^(gpt-|claude-|model:|directory:|permissions:)/i.test(line)) return false;
      return true;
    });
  const summary = candidates.at(-1) ?? "(No readable terminal text.)";
  return summary.length > 180 ? `${summary.slice(0, 177)}…` : summary;
}

function rationaleText(value: string | null): string {
  if (value === null) return "No labeling rationale was recorded.";
  return rationaleDescriptions[value] ?? formatIdentifier(value);
}

function setLabelBadge(badge: HTMLElement, label: string | null): void {
  const key = label ?? "unlabeled";
  badge.textContent = formatLabel(label);
  badge.dataset.label = key;
}

function updateLabelContext(aggregates: Aggregate[]): void {
  const key = labelFilter.value || "all";
  const information = key === "all"
    ? {
        name: "All observations",
        description: "Browse every stored observation, including examples that have not been labeled yet.",
      }
    : labelInformation[key] ?? {
        name: formatIdentifier(key),
        description: "Browse observations with this label.",
      };
  const total = key === "all"
    ? count(aggregates, "total", "all")
    : key === "labeled"
      ? count(aggregates, "labeled", "all")
      : count(aggregates, "label", key);
  element("label-context-name").textContent = information.name;
  element("label-context-count").textContent = `${total.toLocaleString()} stored`;
  element("label-context-description").textContent = information.description;
}

function renderObservations(observations: ObservationSummary[]): void {
  const list = element<HTMLElement>("observation-list");
  const empty = element<HTMLElement>("empty-state");
  list.replaceChildren();
  empty.hidden = observations.length > 0;

  for (const observation of observations) {
    const item = document.createElement("div");
    item.setAttribute("role", "listitem");
    const button = document.createElement("button");
    button.type = "button";
    button.className = "review-item";
    button.dataset.observationId = observation.id;
    button.setAttribute("aria-pressed", String(observation.id === activeObservationID));
    button.addEventListener("click", () => void selectObservation(observation, true));

    const topLine = document.createElement("span");
    topLine.className = "review-item-topline";
    const badge = document.createElement("span");
    badge.className = "label-badge";
    setLabelBadge(badge, observation.label);
    const time = document.createElement("time");
    time.dateTime = observation.recordedAt;
    time.textContent = formatDate(observation.recordedAt);
    topLine.append(badge, time);

    const summary = document.createElement("strong");
    summary.className = "review-item-summary";
    summary.textContent = summarizeTerminal(observation.grid);

    const reason = document.createElement("span");
    reason.className = "review-item-reason";
    reason.textContent = rationaleText(observation.rationale);

    const metadata = document.createElement("span");
    metadata.className = "review-item-metadata";
    metadata.textContent = [
      observation.harness ?? "Unknown harness",
      formatIdentifier(observation.event),
      observation.activityState,
    ].join(" · ");

    button.append(topLine, summary, reason, metadata);
    item.append(button);
    list.append(item);
  }

  const selected = observations.find((observation) => observation.id === activeObservationID)
    ?? observations[0];
  if (selected === undefined) {
    activeObservationID = null;
    element("review-detail-empty").hidden = false;
    element("review-detail-content").hidden = true;
  } else {
    void selectObservation(selected, false);
  }
}

function payloadRecord(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function stringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((entry): entry is string => typeof entry === "string") : [];
}

async function selectObservation(
  observation: ObservationSummary,
  scrollDetail: boolean,
): Promise<void> {
  activeObservationID = observation.id;
  for (const item of document.querySelectorAll<HTMLButtonElement>(".review-item")) {
    const selected = item.dataset.observationId === observation.id;
    item.dataset.selected = String(selected);
    item.setAttribute("aria-pressed", String(selected));
  }

  const request = ++detailRequest;
  const response = await api(`/api/observations/${encodeURIComponent(observation.id)}`);
  const payload: unknown = await responseJSON<unknown>(response);
  if (request !== detailRequest) return;

  const record = payloadRecord(payload);
  const terminal = payloadRecord(record.terminal);
  const grid = stringArray(terminal.grid);
  const labelKey = observation.label ?? "unlabeled";
  const information = labelInformation[labelKey] ?? {
    name: formatIdentifier(labelKey),
    description: "No plain-language description is available for this label.",
  };

  element("review-detail-empty").hidden = true;
  element("review-detail-content").hidden = false;

  const detailLabel = element<HTMLElement>("detail-label");
  setLabelBadge(detailLabel, observation.label);
  element("detail-harness").textContent = observation.harness ?? "Unknown harness";
  element("detail-heading").textContent = summarizeTerminal(observation.grid);
  const detailTime = element<HTMLTimeElement>("detail-time");
  detailTime.dateTime = observation.recordedAt;
  detailTime.textContent = formatDate(observation.recordedAt);
  element("detail-rationale").textContent = rationaleText(observation.rationale);
  element("detail-label-description").textContent = information.description;
  element("detail-event").textContent = formatIdentifier(observation.event);
  element("detail-activity").textContent = formatIdentifier(observation.activityState);
  element("detail-evidence").textContent = formatIdentifier(observation.activityEvidence);
  element("detail-session").textContent = observation.sessionID;

  const confidence = observation.confidence;
  const percentage = confidence === null
    ? null
    : Math.max(0, Math.min(100, Math.round(confidence * 100)));
  element("detail-confidence-value").textContent =
    percentage === null ? "Not recorded" : `${percentage}%`;
  const track = element<HTMLElement>("detail-confidence-track");
  const bar = element<HTMLElement>("detail-confidence-bar");
  if (percentage === null) {
    track.removeAttribute("aria-valuenow");
    track.dataset.empty = "true";
    bar.style.removeProperty("--confidence");
  } else {
    track.setAttribute("aria-valuenow", String(percentage));
    delete track.dataset.empty;
    bar.style.setProperty("--confidence", `${percentage}%`);
  }

  const columns = typeof terminal.columns === "number" ? terminal.columns : observation.columns;
  const rows = typeof terminal.rows === "number" ? terminal.rows : observation.rows;
  element("terminal-size").textContent = `${columns} × ${rows}`;
  element("detail-terminal").textContent = grid.join("\n").trimEnd() || "(Empty terminal grid.)";
  element("detail-payload").textContent = JSON.stringify(payload, null, 2);

  if (scrollDetail && window.matchMedia("(max-width: 799px)").matches) {
    element("review-detail").scrollIntoView({ behavior: "smooth", block: "start" });
  }
}

function renderBundles(bundles: BundleSummary[]): void {
  const body = element<HTMLTableSectionElement>("bundle-rows");
  body.replaceChildren();
  for (const bundle of bundles) {
    const row = document.createElement("tr");
    const imported = document.createElement("td");
    imported.textContent = formatDate(bundle.importedAt);
    const source = document.createElement("td");
    source.textContent = bundle.sourceHost ?? "Unknown host";
    const id = document.createElement("td");
    id.textContent = bundle.id;
    id.title = bundle.id;
    const received = document.createElement("td");
    received.className = "number-column";
    received.textContent = `${bundle.received.toLocaleString()} / ${bundle.expected.toLocaleString()}`;
    row.append(imported, source, id, received);
    body.append(row);
  }
}

function updateHarnesses(aggregates: Aggregate[]): void {
  const selected = harnessFilter.value;
  const options = [new Option("All harnesses", "")];
  for (const aggregate of aggregates.filter((entry) => entry.kind === "harness")) {
    options.push(new Option(`${aggregate.name} (${aggregate.count.toLocaleString()})`, aggregate.name));
  }
  harnessFilter.replaceChildren(...options);
  if (options.some((option) => option.value === selected)) harnessFilter.value = selected;
}

async function loadDashboard(): Promise<void> {
  const parameters = new URLSearchParams({ limit: String(pageSize), offset: String(pageOffset) });
  if (labelFilter.value) parameters.set("label", labelFilter.value);
  if (harnessFilter.value) parameters.set("harness", harnessFilter.value);
  const data = await responseJSON<DashboardResponse>(await api(`/api/dashboard?${parameters}`));
  showDashboard();

  element("stat-observations").textContent = count(data.aggregates, "total", "all").toLocaleString();
  element("stat-labeled").textContent = count(data.aggregates, "labeled", "all").toLocaleString();
  element("stat-sessions").textContent = count(data.aggregates, "session", "all").toLocaleString();
  element("stat-bundles").textContent = data.bundles.length.toLocaleString();
  updateHarnesses(data.aggregates);
  updateLabelContext(data.aggregates);
  renderObservations(data.observations);
  renderBundles(data.bundles);
  element("dataset-tools-count").textContent =
    `${data.bundles.length.toLocaleString()} ${data.bundles.length === 1 ? "bundle" : "bundles"}`;

  const first = data.pagination.returned > 0 ? data.pagination.offset + 1 : 0;
  const last = data.pagination.offset + data.pagination.returned;
  element("page-status").textContent = `Showing ${first.toLocaleString()}–${last.toLocaleString()}`;
  previousPage.disabled = pageOffset === 0;
  nextPage.disabled = data.pagination.returned < data.pagination.limit;
}

function fileMap(files: File[]): Map<string, File> {
  const map = new Map<string, File>();
  for (const file of files) {
    const path = file.webkitRelativePath || file.name;
    map.set(path, file);
    const slash = path.indexOf("/");
    if (slash >= 0) map.set(path.slice(slash + 1), file);
  }
  return map;
}

function manifestFile(files: File[]): File | undefined {
  return files.find((file) => file.name === "manifest.json");
}

function validManifest(value: unknown): value is StudyManifest {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  if (!("files" in value) || !Array.isArray(value.files)) return false;
  if (!("totals" in value) || typeof value.totals !== "object" || value.totals === null) return false;
  return (
    "bundleSchemaVersion" in value
    && value.bundleSchemaVersion === 1
    && "observationSchemaVersion" in value
    && value.observationSchemaVersion === 1
    && "bundleID" in value
    && typeof value.bundleID === "string"
    && "createdAt" in value
    && typeof value.createdAt === "string"
    && "observations" in value.totals
    && typeof value.totals.observations === "number"
  );
}

async function readManifest(files: File[]): Promise<StudyManifest> {
  const file = manifestFile(files);
  if (file === undefined) throw new Error("The selected directory has no manifest.json file.");
  const parsed: unknown = JSON.parse(await file.text());
  if (!validManifest(parsed)) throw new Error("The selected manifest is not a Cherry attention bundle.");
  for (const entry of parsed.files) {
    if (
      typeof entry !== "object"
      || entry === null
      || !("relativePath" in entry)
      || typeof entry.relativePath !== "string"
      || !("observationCount" in entry)
      || typeof entry.observationCount !== "number"
    ) {
      throw new Error("The selected manifest contains an invalid file entry.");
    }
  }
  return parsed;
}

async function* lines(file: File): AsyncGenerator<string> {
  const reader = file.stream().getReader();
  const decoder = new TextDecoder();
  let pending = "";
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) break;
    pending += decoder.decode(chunk.value, { stream: true });
    const pieces = pending.split(/\r?\n/);
    pending = pieces.pop() ?? "";
    for (const line of pieces) if (line.trim().length > 0) yield line;
  }
  pending += decoder.decode();
  if (pending.trim().length > 0) yield pending;
}

async function sendChunk(bundleID: string, observations: unknown[]): Promise<{ inserted: number }> {
  return responseJSON<{ inserted: number }>(await api(
    `/api/bundles/${encodeURIComponent(bundleID)}/observations`,
    { method: "POST", body: JSON.stringify({ observations }) },
  ));
}

async function uploadBundle(): Promise<void> {
  uploadButton.disabled = true;
  uploadStatus.dataset.error = "false";
  try {
    const manifest = await readManifest(selectedFiles);
    const files = fileMap(selectedFiles);
    await responseJSON(await api("/api/bundles", { method: "POST", body: JSON.stringify(manifest) }));

    let processed = 0;
    let inserted = 0;
    let chunk: unknown[] = [];
    let chunkBytes = 0;
    for (const entry of manifest.files) {
      const file = files.get(entry.relativePath);
      if (file === undefined) throw new Error(`Missing ${entry.relativePath} from the selected directory.`);
      for await (const line of lines(file)) {
        const observation: unknown = JSON.parse(line);
        const bytes = new TextEncoder().encode(line).byteLength;
        if (chunk.length > 0 && (chunk.length >= 16 || chunkBytes + bytes > 800_000)) {
          inserted += (await sendChunk(manifest.bundleID, chunk)).inserted;
          chunk = [];
          chunkBytes = 0;
        }
        chunk.push(observation);
        chunkBytes += bytes;
        processed += 1;
        uploadStatus.textContent = `Uploading ${processed.toLocaleString()} of ${manifest.totals.observations.toLocaleString()} observations…`;
      }
    }
    if (chunk.length > 0) inserted += (await sendChunk(manifest.bundleID, chunk)).inserted;

    uploadStatus.textContent = `Import complete. ${inserted.toLocaleString()} new observations stored; ${(
      processed - inserted
    ).toLocaleString()} duplicates skipped.`;
    pageOffset = 0;
    await loadDashboard();
  } catch (error) {
    uploadStatus.dataset.error = "true";
    uploadStatus.textContent = error instanceof Error ? error.message : "Import failed.";
  } finally {
    uploadButton.disabled = selectedFiles.length === 0;
  }
}

loginForm.addEventListener("submit", (event) => {
  event.preventDefault();
  token = tokenInput.value;
  sessionStorage.setItem(tokenKey, token);
  loginMessage.textContent = "Connecting…";
  loginMessage.dataset.error = "false";
  void loadDashboard().catch((error) => {
    if (token.length > 0) showLogin(error instanceof Error ? error.message : "Could not connect.");
  });
});

element("change-token").addEventListener("click", () => {
  sessionStorage.removeItem(tokenKey);
  token = "";
  showLogin();
});

bundleInput.addEventListener("change", () => {
  selectedFiles = Array.from(bundleInput.files ?? []);
  const file = manifestFile(selectedFiles);
  element("selected-bundle").textContent = file?.webkitRelativePath.split("/")[0] || "No bundle selected";
  element("selected-detail").textContent = `${selectedFiles.length.toLocaleString()} files selected.`;
  uploadButton.disabled = file === undefined;
  uploadStatus.textContent = "";
});

uploadButton.addEventListener("click", () => void uploadBundle());
labelFilter.addEventListener("change", () => {
  pageOffset = 0;
  void loadDashboard();
});
harnessFilter.addEventListener("change", () => {
  pageOffset = 0;
  void loadDashboard();
});
previousPage.addEventListener("click", () => {
  pageOffset = Math.max(0, pageOffset - pageSize);
  void loadDashboard();
});
nextPage.addEventListener("click", () => {
  pageOffset += pageSize;
  void loadDashboard();
});
if (token.length > 0) {
  void loadDashboard().catch(() => showLogin("Could not connect with the saved token."));
} else {
  showLogin();
}

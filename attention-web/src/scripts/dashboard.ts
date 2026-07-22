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
const detailDialog = element<HTMLDialogElement>("detail-dialog");

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
  if (value === null) return "Unlabeled";
  return value.replaceAll("_", " ").replace(/^./, (character) => character.toUpperCase());
}

function formatDate(value: string): string {
  const date = new Date(value);
  return Number.isFinite(date.getTime())
    ? new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date)
    : value;
}

function renderObservations(observations: ObservationSummary[]): void {
  const grid = element<HTMLElement>("observation-grid");
  const empty = element<HTMLElement>("empty-state");
  grid.replaceChildren();
  empty.hidden = observations.length > 0;

  for (const observation of observations) {
    const card = document.createElement("button");
    card.type = "button";
    card.className = "observation-card";
    card.addEventListener("click", () => void openObservation(observation.id));

    const metadata = document.createElement("div");
    metadata.className = "observation-meta";
    const harness = document.createElement("strong");
    harness.textContent = observation.harness ?? "Unknown harness";
    const badge = document.createElement("span");
    badge.className = "label-badge";
    badge.textContent = formatLabel(observation.label);
    if (observation.label === null) badge.dataset.unlabeled = "true";
    const time = document.createElement("time");
    time.dateTime = observation.recordedAt;
    time.textContent = formatDate(observation.recordedAt);
    metadata.append(harness, badge, time);

    const terminal = document.createElement("pre");
    terminal.className = "terminal-preview";
    terminal.textContent = observation.grid.slice(-36).join("\n") || "(empty terminal grid)";
    card.append(metadata, terminal);
    grid.append(card);
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
  renderObservations(data.observations);
  renderBundles(data.bundles);

  const first = data.pagination.returned > 0 ? data.pagination.offset + 1 : 0;
  const last = data.pagination.offset + data.pagination.returned;
  element("page-status").textContent = `Showing ${first.toLocaleString()}–${last.toLocaleString()}`;
  previousPage.disabled = pageOffset === 0;
  nextPage.disabled = data.pagination.returned < data.pagination.limit;
}

async function openObservation(id: string): Promise<void> {
  const response = await api(`/api/observations/${encodeURIComponent(id)}`);
  const payload: unknown = await responseJSON<unknown>(response);
  element("detail-title").textContent = `${id.slice(0, 8)} observation.`;
  element("detail-payload").textContent = JSON.stringify(payload, null, 2);
  detailDialog.showModal();
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
element("close-detail").addEventListener("click", () => detailDialog.close());
detailDialog.addEventListener("click", (event) => {
  if (event.target === detailDialog) detailDialog.close();
});

if (token.length > 0) {
  void loadDashboard().catch(() => showLogin("Could not connect with the saved token."));
} else {
  showLogin();
}

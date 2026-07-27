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
type TerminalColor = {
  space: "ansi16" | "palette256" | "rgb";
  components: number[];
};
type StyledTerminalRun = {
  text: string;
  foreground: TerminalColor | null;
  background: TerminalColor | null;
  attributes: string[];
};
type ObservationSummary = {
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
  grid: string[];
  activityState: string;
  activityEvidence: string;
  reviewStatus: "accepted" | "corrected" | "skipped" | null;
  reviewLabel: "attention_needed" | "no_attention_needed" | "unknown" | null;
  reviewReason: string | null;
  reviewSource: "human" | "assistant_audit" | null;
  reviewedAt: string | null;
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
  pagination: { limit: number; offset: number; returned: number; total: number };
};
type ReviewResponse = {
  observationID: string;
  review: {
    status: "accepted" | "corrected" | "skipped";
    label: "attention_needed" | "no_attention_needed" | "unknown" | null;
    reason: string | null;
    reviewedAt: string;
  };
};

const tokenKey = "cherry-attention-dashboard-token";
const pageSize = 1;
let token = sessionStorage.getItem(tokenKey) ?? "";
let selectedFiles: File[] = [];
let pageOffset = 0;
let detailRequest = 0;
let currentObservation: ObservationSummary | null = null;
let reviewBusy = false;
let reviewNotice = "";

type LabelInformation = {
  name: string;
  description: string;
};

const labelInformation: Record<string, LabelInformation> = {
  attention_needed: {
    name: "Attention needed",
    description: "The agent needs you to review a result, provide input, approve an action, or resolve a problem.",
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

const reasonInformation: Record<string, LabelInformation> = {
  result_ready: {
    name: "Result ready",
    description: "The agent completed its turn and returned control to you.",
  },
  waiting_for_input: {
    name: "Waiting for input",
    description: "The agent is at a prompt and needs information or a new instruction.",
  },
  waiting_for_approval: {
    name: "Waiting for approval",
    description: "The agent is blocked until you approve or reject an action.",
  },
  blocked_or_error: {
    name: "Blocked or error",
    description: "The agent stopped because it encountered an interruption or problem.",
  },
};

const reviewInformation: Record<string, LabelInformation> = {
  pending: {
    name: "Pending review",
    description: "Provisional examples that have not received a human decision.",
  },
  reviewed: {
    name: "Reviewed",
    description: "Examples whose provisional label was accepted or corrected.",
  },
  accepted: {
    name: "Accepted",
    description: "Examples where the provisional label matched the human decision.",
  },
  corrected: {
    name: "Corrected",
    description: "Examples where the human decision replaced the provisional label.",
  },
  skipped: {
    name: "Skipped",
    description: "Examples set aside because they need more context or another pass.",
  },
  all: {
    name: "All review states",
    description: "Every example, regardless of its human-review status.",
  },
};

const rationaleDescriptions: Record<string, string> = {
  active_working_indicator: "The terminal showed an active working indicator.",
  ambiguous_post_resume_prompt: "The prompt appeared after a resume, but the next expected action was unclear.",
  approval_prompt_visible: "The terminal contained an explicit request for approval.",
  blocked_or_error_visible: "The terminal showed an interruption or error that stopped normal progress.",
  completed_turn_at_prompt: "The agent completed its turn and returned to an idle prompt.",
  explicit_confirmation_request: "The terminal contained an explicit request for confirmation.",
  interrupted_conversation: "The conversation was interrupted before reaching a normal completion.",
  resume_picker_ui: "A session-resume picker was visible and needed a human choice.",
  startup_authentication_error: "The harness reported an authentication problem during startup.",
  user_composing_at_prompt: "The user had started composing input at an idle prompt.",
  waiting_at_prompt: "The harness was idle at a prompt and waiting for a user action.",
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
const reviewFilter = element<HTMLSelectElement>("review-filter");
const previousPage = element<HTMLButtonElement>("previous-page");
const nextPage = element<HTMLButtonElement>("next-page");
const reviewForm = element<HTMLFormElement>("review-form");
const reviewLabel = element<HTMLSelectElement>("review-label");
const reviewReason = element<HTMLSelectElement>("review-reason");
const acceptReview = element<HTMLButtonElement>("accept-review");
const correctReview = element<HTMLButtonElement>("correct-review");
const skipReview = element<HTMLButtonElement>("skip-review");
const reviewMessage = element<HTMLElement>("review-message");

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

function formatLastEdit(milliseconds: number | null): string {
  if (milliseconds === null) return "Last edit time was not captured.";
  if (milliseconds < 1_000) return "Last edit was less than a second before capture.";
  const seconds = Math.round(milliseconds / 1_000);
  if (seconds < 60) return `Last edit was ${seconds.toLocaleString()} seconds before capture.`;
  const minutes = Math.round(seconds / 60);
  return `Last edit was ${minutes.toLocaleString()} ${minutes === 1 ? "minute" : "minutes"} before capture.`;
}

function setLabelBadge(badge: HTMLElement, label: string | null): void {
  const key = label ?? "unlabeled";
  badge.textContent = formatLabel(label);
  badge.dataset.label = key;
}

function updateLabelContext(filteredTotal: number): void {
  const key = labelFilter.value || "all";
  const label = key === "all"
    ? {
        name: "All observations",
        description: "Browse every stored observation, including examples that have not been labeled yet.",
      }
    : labelInformation[key] ?? {
        name: formatIdentifier(key),
        description: "Browse observations with this label.",
      };
  const review = reviewInformation[reviewFilter.value] ?? reviewInformation.all;
  element("label-context-name").textContent = `${review.name} · ${label.name}`;
  element("label-context-count").textContent = `${filteredTotal.toLocaleString()} stored`;
  element("label-context-description").textContent =
    `${review.description} ${label.description}`;
}

function renderObservations(observations: ObservationSummary[]): void {
  const selected = observations[0];
  if (selected === undefined) {
    currentObservation = null;
    element("review-detail-empty").hidden = false;
    element("review-detail-content").hidden = true;
  } else {
    currentObservation = selected;
    void selectObservation(selected);
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

function terminalColor(value: unknown): TerminalColor | null {
  const record = payloadRecord(value);
  const space = record.space;
  const components = record.components;
  if (
    (space !== "ansi16" && space !== "palette256" && space !== "rgb")
    || !Array.isArray(components)
    || !components.every((component) => Number.isInteger(component))
  ) {
    return null;
  }
  return { space, components: components as number[] };
}

function styledTerminalGrid(value: unknown, lineCount: number): StyledTerminalRun[][] | null {
  if (!Array.isArray(value) || value.length !== lineCount) return null;
  const lines: StyledTerminalRun[][] = [];
  for (const valueLine of value) {
    if (!Array.isArray(valueLine)) return null;
    const line: StyledTerminalRun[] = [];
    for (const valueRun of valueLine) {
      const run = payloadRecord(valueRun);
      if (
        typeof run.text !== "string"
        || !Array.isArray(run.attributes)
        || !run.attributes.every((attribute) => typeof attribute === "string")
      ) {
        return null;
      }
      line.push({
        text: run.text,
        foreground: run.foreground === undefined || run.foreground === null
          ? null
          : terminalColor(run.foreground),
        background: run.background === undefined || run.background === null
          ? null
          : terminalColor(run.background),
        attributes: run.attributes as string[],
      });
    }
    lines.push(line);
  }
  return lines;
}

const ansi16Colors = [
  "#000000", "#cd0000", "#00cd00", "#cdcd00",
  "#0000ee", "#cd00cd", "#00cdcd", "#e5e5e5",
  "#7f7f7f", "#ff0000", "#00ff00", "#ffff00",
  "#5c5cff", "#ff00ff", "#00ffff", "#ffffff",
];

function byte(value: number): number {
  return Math.max(0, Math.min(255, value));
}

function cssTerminalColor(color: TerminalColor | null): string | null {
  if (color === null) return null;
  if (color.space === "ansi16") {
    const index = color.components[0];
    return typeof index === "number" ? ansi16Colors[index] ?? null : null;
  }
  if (color.space === "rgb" && color.components.length === 3) {
    return `rgb(${color.components.map(byte).join(" ")})`;
  }
  const index = color.components[0];
  if (color.space !== "palette256" || typeof index !== "number" || index < 0 || index > 255) {
    return null;
  }
  if (index < 16) return ansi16Colors[index] ?? null;
  if (index >= 232) {
    const level = 8 + ((index - 232) * 10);
    return `rgb(${level} ${level} ${level})`;
  }
  const offset = index - 16;
  const levels = [0, 95, 135, 175, 215, 255];
  const red = levels[Math.floor(offset / 36)] ?? 0;
  const green = levels[Math.floor((offset % 36) / 6)] ?? 0;
  const blue = levels[offset % 6] ?? 0;
  return `rgb(${red} ${green} ${blue})`;
}

function renderTerminal(
  target: HTMLElement,
  grid: string[],
  styledValue: unknown,
): boolean {
  const styledGrid = styledTerminalGrid(styledValue, grid.length);
  if (styledGrid === null) {
    target.textContent = grid.join("\n").trimEnd() || "(Empty terminal grid.)";
    return false;
  }

  const fragment = document.createDocumentFragment();
  styledGrid.forEach((line, lineIndex) => {
    for (const run of line) {
      const span = document.createElement("span");
      span.className = "terminal-run";
      span.textContent = run.text;

      let foreground = cssTerminalColor(run.foreground);
      let background = cssTerminalColor(run.background);
      const attributes = new Set(run.attributes);
      if (attributes.has("inverse")) {
        [foreground, background] = [
          background ?? "var(--terminal-background)",
          foreground ?? "var(--terminal-foreground)",
        ];
      }
      if (foreground !== null) span.style.setProperty("--run-foreground", foreground);
      if (background !== null) span.style.setProperty("--run-background", background);
      if (attributes.has("bold")) span.classList.add("terminal-run--bold");
      if (attributes.has("dim")) span.classList.add("terminal-run--dim");
      if (attributes.has("italic")) span.classList.add("terminal-run--italic");
      const decorations = [
        attributes.has("underline") ? "underline" : null,
        attributes.has("strikethrough") ? "line-through" : null,
      ].filter((value): value is string => value !== null);
      if (decorations.length > 0) span.style.textDecorationLine = decorations.join(" ");
      fragment.append(span);
    }
    if (lineIndex < styledGrid.length - 1) fragment.append("\n");
  });
  target.replaceChildren(fragment);
  return true;
}

function updateReasonControl(): void {
  const needsReason = reviewLabel.value === "attention_needed";
  if (needsReason && reviewReason.value === "") reviewReason.value = "result_ready";
  if (!needsReason) reviewReason.value = "";
  reviewReason.disabled = reviewBusy || !needsReason;
}

function setReviewControlsDisabled(disabled: boolean): void {
  reviewLabel.disabled = disabled;
  acceptReview.disabled = disabled || currentObservation?.label === null;
  correctReview.disabled = disabled;
  skipReview.disabled = disabled;
  updateReasonControl();
}

function renderHumanReview(observation: ObservationSummary): void {
  const status = observation.reviewStatus ?? "pending";
  const badge = element<HTMLElement>("review-status-badge");
  badge.dataset.status = status;
  badge.textContent = formatIdentifier(status);

  const selectedLabel = observation.reviewLabel ?? observation.label ?? "unknown";
  reviewLabel.value =
    selectedLabel === "attention_needed"
    || selectedLabel === "no_attention_needed"
    || selectedLabel === "unknown"
      ? selectedLabel
      : "unknown";
  const selectedReason = observation.reviewReason ?? observation.reason;
  reviewReason.value = reviewLabel.value !== "attention_needed"
    ? ""
    : selectedReason !== null && reasonInformation[selectedReason] !== undefined
      ? selectedReason
      : "result_ready";
  reviewBusy = false;
  setReviewControlsDisabled(false);

  const reviewed = observation.reviewedAt === null ? "" : ` Last saved ${formatDate(observation.reviewedAt)}.`;
  const source = observation.reviewSource === "assistant_audit"
    ? " Assistant-audited."
    : observation.reviewSource === "human"
      ? " Manually reviewed."
      : "";
  element("review-hint").textContent = status === "pending"
    ? "Accept the provisional suggestion, or choose a correction."
    : `This example is ${formatIdentifier(status).toLowerCase()}.${source}${reviewed} You can replace the decision.`;
  reviewMessage.textContent = reviewNotice;
  reviewNotice = "";
  delete reviewMessage.dataset.error;
}

async function selectObservation(observation: ObservationSummary): Promise<void> {
  const request = ++detailRequest;
  const response = await api(`/api/observations/${encodeURIComponent(observation.id)}`);
  const payload: unknown = await responseJSON<unknown>(response);
  if (request !== detailRequest) return;

  const record = payloadRecord(payload);
  const terminal = payloadRecord(record.terminal);
  const interaction = payloadRecord(record.interaction);
  const grid = stringArray(terminal.grid);
  const labelKey = observation.label ?? "unlabeled";
  const information = labelInformation[labelKey] ?? {
    name: formatIdentifier(labelKey),
    description: "No plain-language description is available for this label.",
  };
  const reason = observation.reason === null
    ? null
    : reasonInformation[observation.reason] ?? {
        name: formatIdentifier(observation.reason),
        description: "No plain-language description is available for this reason.",
      };

  element("review-detail-empty").hidden = true;
  element("review-detail-content").hidden = false;

  const detailLabel = element<HTMLElement>("detail-label");
  setLabelBadge(detailLabel, observation.label);
  const detailReason = element<HTMLElement>("detail-reason");
  detailReason.hidden = reason === null;
  if (reason !== null) {
    detailReason.textContent = reason.name;
    detailReason.dataset.reason = observation.reason ?? "";
  } else {
    detailReason.textContent = "";
    delete detailReason.dataset.reason;
  }
  element("detail-harness").textContent = observation.harness ?? "Unknown harness";
  element("detail-heading").textContent = summarizeTerminal(observation.grid);
  const detailTime = element<HTMLTimeElement>("detail-time");
  detailTime.dateTime = observation.recordedAt;
  detailTime.textContent = formatDate(observation.recordedAt);
  element("detail-rationale").textContent = rationaleText(observation.rationale);
  element("detail-label-description").textContent = reason?.description ?? information.description;
  element("detail-event").textContent = formatIdentifier(observation.event);
  element("detail-activity").textContent = formatIdentifier(observation.activityState);
  element("detail-evidence").textContent = formatIdentifier(observation.activityEvidence);
  element("detail-session").textContent = observation.sessionID;

  const hasUnsubmittedInput = typeof interaction.hasUnsubmittedInput === "boolean"
    ? interaction.hasUnsubmittedInput
    : null;
  const millisecondsSinceLastKeystroke =
    typeof interaction.millisecondsSinceLastKeystroke === "number"
    && Number.isFinite(interaction.millisecondsSinceLastKeystroke)
      ? Math.max(0, interaction.millisecondsSinceLastKeystroke)
      : null;
  const terminalFocused = typeof interaction.terminalFocused === "boolean"
    ? interaction.terminalFocused
    : null;
  const interactionSummary = element<HTMLElement>("interaction-summary");
  const hasInteractionData = hasUnsubmittedInput !== null || terminalFocused !== null;
  interactionSummary.hidden = !hasInteractionData;
  if (hasInteractionData) {
    interactionSummary.dataset.draft = String(hasUnsubmittedInput === true);
    element("detail-interaction-title").textContent = hasUnsubmittedInput
      ? "Unsubmitted input detected."
      : "No unsubmitted input detected.";
    const focusDescription = terminalFocused === null
      ? "Focus state was not captured."
      : terminalFocused
        ? "The terminal was focused."
        : "The terminal was not focused.";
    const evidenceDescription = hasUnsubmittedInput
      ? " Suggested evidence: user composing."
      : "";
    element("detail-interaction-description").textContent =
      `${formatLastEdit(millisecondsSinceLastKeystroke)} ${focusDescription}${evidenceDescription}`;
  }

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
  const hasColor = renderTerminal(
    element("detail-terminal"),
    grid,
    terminal.styledGrid,
  );
  const renderMode = element("terminal-render-mode");
  renderMode.textContent = hasColor ? "ANSI color" : "Plain text";
  renderMode.dataset.colored = String(hasColor);
  renderMode.title = hasColor
    ? "Foreground, background, and text attributes were retained by Cherry."
    : "This observation was captured without terminal style information.";
  element("detail-payload").textContent = JSON.stringify(payload, null, 2);
  renderHumanReview(observation);
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
  if (reviewFilter.value) parameters.set("review", reviewFilter.value);
  const data = await responseJSON<DashboardResponse>(await api(`/api/dashboard?${parameters}`));
  if (data.pagination.returned === 0 && data.pagination.total > 0 && pageOffset > 0) {
    pageOffset = Math.max(0, data.pagination.total - 1);
    await loadDashboard();
    return;
  }
  showDashboard();

  element("stat-observations").textContent = count(data.aggregates, "total", "all").toLocaleString();
  element("stat-labeled").textContent = count(data.aggregates, "labeled", "all").toLocaleString();
  element("stat-reviewed").textContent = count(data.aggregates, "review", "reviewed").toLocaleString();
  element("stat-pending").textContent = count(data.aggregates, "review", "pending").toLocaleString();
  updateHarnesses(data.aggregates);
  updateLabelContext(data.pagination.total);
  renderObservations(data.observations);
  renderBundles(data.bundles);
  element("dataset-tools-count").textContent =
    `${data.bundles.length.toLocaleString()} ${data.bundles.length === 1 ? "bundle" : "bundles"}`;

  const current = data.pagination.returned > 0 ? data.pagination.offset + 1 : 0;
  element("page-status").textContent = current === 0
    ? "No observations"
    : `Observation ${current.toLocaleString()} of ${data.pagination.total.toLocaleString()}`;
  previousPage.disabled = pageOffset === 0;
  nextPage.disabled = current >= data.pagination.total;
}

function reviewFilterContains(status: ReviewResponse["review"]["status"]): boolean {
  const filter = reviewFilter.value;
  return filter === "all"
    || filter === status
    || (filter === "reviewed" && (status === "accepted" || status === "corrected"));
}

async function submitReview(action: "accept" | "correct" | "skip"): Promise<void> {
  if (currentObservation === null || reviewBusy) return;
  const observationID = currentObservation.id;
  const body = action === "correct"
    ? {
        action,
        label: reviewLabel.value,
        reason: reviewLabel.value === "attention_needed" ? reviewReason.value : null,
      }
    : { action };

  reviewBusy = true;
  setReviewControlsDisabled(true);
  reviewMessage.textContent = "Saving review…";
  delete reviewMessage.dataset.error;
  try {
    const result = await responseJSON<ReviewResponse>(await api(
      `/api/observations/${encodeURIComponent(observationID)}/review`,
      { method: "PUT", body: JSON.stringify(body) },
    ));
    if (reviewFilterContains(result.review.status)) pageOffset += pageSize;
    reviewNotice = action === "accept"
      ? "Suggestion accepted. Next observation loaded."
      : action === "correct"
        ? "Correction saved. Next observation loaded."
        : "Observation skipped. Next observation loaded.";
    await loadDashboard();
    if (currentObservation === null) {
      element("page-status").textContent = "Review saved. Queue complete.";
      reviewNotice = "";
    }
  } catch (error) {
    reviewBusy = false;
    setReviewControlsDisabled(false);
    reviewMessage.dataset.error = "true";
    reviewMessage.textContent = error instanceof Error ? error.message : "Could not save this review.";
  }
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
reviewFilter.addEventListener("change", () => {
  pageOffset = 0;
  void loadDashboard();
});
harnessFilter.addEventListener("change", () => {
  pageOffset = 0;
  void loadDashboard();
});
previousPage.addEventListener("click", () => {
  pageOffset = Math.max(0, pageOffset - pageSize);
  void loadDashboard().then(() => {
    element("review-navigation").scrollIntoView({ behavior: "smooth", block: "start" });
  });
});
nextPage.addEventListener("click", () => {
  pageOffset += pageSize;
  void loadDashboard().then(() => {
    element("review-navigation").scrollIntoView({ behavior: "smooth", block: "start" });
  });
});
reviewLabel.addEventListener("change", updateReasonControl);
reviewForm.addEventListener("submit", (event) => {
  event.preventDefault();
  void submitReview("correct");
});
acceptReview.addEventListener("click", () => void submitReview("accept"));
skipReview.addEventListener("click", () => void submitReview("skip"));
document.addEventListener("keydown", (event) => {
  if (
    currentObservation === null
    || reviewBusy
    || event.metaKey
    || event.ctrlKey
    || event.altKey
    || event.shiftKey
  ) {
    return;
  }
  const target = event.target;
  if (
    target instanceof HTMLInputElement
    || target instanceof HTMLSelectElement
    || target instanceof HTMLTextAreaElement
    || target instanceof HTMLButtonElement
  ) {
    return;
  }
  const key = event.key.toLowerCase();
  if (key !== "a" && key !== "c" && key !== "s") return;
  event.preventDefault();
  void submitReview(key === "a" ? "accept" : key === "c" ? "correct" : "skip");
});
if (token.length > 0) {
  void loadDashboard().catch(() => showLogin("Could not connect with the saved token."));
} else {
  showLogin();
}

const observationEvents = new Set([
  "content_changed",
  "input_changed",
  "input_submitted",
  "activity_state_changed",
  "notification",
  "process_exited",
  "labeled_checkpoint",
]);

const attentionLabels = new Set([
  "attention_needed",
  "no_attention_needed",
  "unknown",
  // Legacy schema-1 labels remain uploadable so old bundles can still be
  // imported. The dashboard normalizes these into attention_needed + reason.
  "approval_required",
  "waiting_for_input",
  "ready_for_review",
]);

const attentionReasons = new Set([
  "result_ready",
  "waiting_for_input",
  "waiting_for_approval",
  "blocked_or_error",
]);

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export const maximumUploadObservations = 16;
export const maximumRequestBytes = 1_000_000;
export const maximumObservationBytes = 750_000;

export type ObservationRecord = {
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
  gridJSON: string;
  activityState: string;
  activityEvidence: string;
  payloadJSON: string;
};

export type BundleRecord = {
  id: string;
  sourceHost: string | null;
  createdAt: string;
  expectedObservations: number;
};

export class ValidationError extends Error {}

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function objectValue(value: unknown, description: string): Record<string, unknown> {
  if (!isObject(value)) {
    throw new ValidationError(`${description} must be an object`);
  }
  return value;
}

function requiredString(value: unknown, description: string, maximumLength = 200): string {
  if (typeof value !== "string" || value.length === 0 || value.length > maximumLength) {
    throw new ValidationError(`${description} must be a non-empty string of at most ${maximumLength} characters`);
  }
  return value;
}

function optionalString(value: unknown, description: string, maximumLength = 200): string | null {
  if (value === undefined || value === null) return null;
  return requiredString(value, description, maximumLength);
}

function integerValue(value: unknown, description: string, minimum: number, maximum: number): number {
  if (!Number.isInteger(value) || typeof value !== "number" || value < minimum || value > maximum) {
    throw new ValidationError(`${description} must be an integer from ${minimum} to ${maximum}`);
  }
  return value;
}

function booleanValue(value: unknown, description: string): boolean {
  if (typeof value !== "boolean") {
    throw new ValidationError(`${description} must be a boolean`);
  }
  return value;
}

function numberValue(value: unknown, description: string, minimum: number, maximum: number): number {
  if (typeof value !== "number" || !Number.isFinite(value) || value < minimum || value > maximum) {
    throw new ValidationError(`${description} must be a number from ${minimum} to ${maximum}`);
  }
  return value;
}

function isoDate(value: unknown, description: string): string {
  const text = requiredString(value, description, 64);
  if (!Number.isFinite(Date.parse(text))) {
    throw new ValidationError(`${description} must be an ISO-8601 date`);
  }
  return text;
}

function validateTerminalColor(value: unknown, description: string): void {
  const color = objectValue(value, description);
  const space = requiredString(color.space, `${description}.space`, 32);
  if (!Array.isArray(color.components)) {
    throw new ValidationError(`${description}.components must be an array`);
  }
  if (space === "ansi16" || space === "palette256") {
    const maximum = space === "ansi16" ? 15 : 255;
    if (color.components.length !== 1) {
      throw new ValidationError(`${description}.components must contain one index`);
    }
    integerValue(color.components[0], `${description}.components[0]`, 0, maximum);
    return;
  }
  if (space === "rgb") {
    if (color.components.length !== 3) {
      throw new ValidationError(`${description}.components must contain red, green, and blue`);
    }
    color.components.forEach((component, index) => {
      integerValue(component, `${description}.components[${index}]`, 0, 255);
    });
    return;
  }
  throw new ValidationError(`${description}.space is unsupported`);
}

function validateStyledGrid(value: unknown, gridLineCount: number): void {
  if (!Array.isArray(value) || value.length !== gridLineCount) {
    throw new ValidationError("observation.terminal.styledGrid must correspond to terminal.grid");
  }
  const attributes = new Set([
    "bold", "dim", "inverse", "italic", "underline", "strikethrough",
  ]);
  value.forEach((line, lineIndex) => {
    if (!Array.isArray(line) || line.length > 1_024) {
      throw new ValidationError(`observation.terminal.styledGrid[${lineIndex}] is invalid`);
    }
    let textLength = 0;
    line.forEach((run, runIndex) => {
      const description = `observation.terminal.styledGrid[${lineIndex}][${runIndex}]`;
      const styledRun = objectValue(run, description);
      const text = requiredString(styledRun.text, `${description}.text`, 1_024);
      textLength += text.length;
      if (textLength > 1_024) {
        throw new ValidationError(`observation.terminal.styledGrid[${lineIndex}] is too long`);
      }
      if (!Array.isArray(styledRun.attributes) || styledRun.attributes.length > attributes.size) {
        throw new ValidationError(`${description}.attributes is invalid`);
      }
      for (const attribute of styledRun.attributes) {
        if (typeof attribute !== "string" || !attributes.has(attribute)) {
          throw new ValidationError(`${description}.attributes contains an unsupported value`);
        }
      }
      if (styledRun.foreground !== undefined && styledRun.foreground !== null) {
        validateTerminalColor(styledRun.foreground, `${description}.foreground`);
      }
      if (styledRun.background !== undefined && styledRun.background !== null) {
        validateTerminalColor(styledRun.background, `${description}.background`);
      }
    });
  });
}

export function parseBundle(value: unknown): BundleRecord {
  const bundle = objectValue(value, "bundle");
  if (bundle.bundleSchemaVersion !== 1 || bundle.observationSchemaVersion !== 1) {
    throw new ValidationError("unsupported bundle or observation schema version");
  }

  const id = requiredString(bundle.bundleID, "bundle.bundleID", 64);
  if (!uuidPattern.test(id)) throw new ValidationError("bundle.bundleID must be a UUID");
  const totals = objectValue(bundle.totals, "bundle.totals");

  return {
    id,
    sourceHost: optionalString(bundle.sourceHost, "bundle.sourceHost", 255),
    createdAt: isoDate(bundle.createdAt, "bundle.createdAt"),
    expectedObservations: integerValue(
      totals.observations,
      "bundle.totals.observations",
      0,
      10_000_000,
    ),
  };
}

export function parseObservation(value: unknown): ObservationRecord {
  const observation = objectValue(value, "observation");
  if (observation.schemaVersion !== 1) {
    throw new ValidationError("unsupported observation schema version");
  }

  const id = requiredString(observation.id, "observation.id", 64);
  if (!uuidPattern.test(id)) throw new ValidationError("observation.id must be a UUID");

  const event = requiredString(observation.event, "observation.event", 64);
  if (!observationEvents.has(event)) throw new ValidationError(`unsupported observation event: ${event}`);

  const label = optionalString(observation.label, "observation.label", 64);
  if (label !== null && !attentionLabels.has(label)) {
    throw new ValidationError(`unsupported observation label: ${label}`);
  }

  const session = objectValue(observation.session, "observation.session");
  const terminal = objectValue(observation.terminal, "observation.terminal");
  const activity = objectValue(observation.activity, "observation.activity");
  if (observation.interaction !== undefined && observation.interaction !== null) {
    const interaction = objectValue(observation.interaction, "observation.interaction");
    booleanValue(
      interaction.hasUnsubmittedInput,
      "observation.interaction.hasUnsubmittedInput",
    );
    if (
      interaction.millisecondsSinceLastKeystroke !== undefined
      && interaction.millisecondsSinceLastKeystroke !== null
    ) {
      integerValue(
        interaction.millisecondsSinceLastKeystroke,
        "observation.interaction.millisecondsSinceLastKeystroke",
        0,
        2_147_483_647,
      );
    }
    booleanValue(interaction.terminalFocused, "observation.interaction.terminalFocused");
  }
  if (observation.annotation !== undefined && observation.annotation !== null) {
    const annotation = objectValue(observation.annotation, "observation.annotation");
    if (annotation.schemaVersion !== undefined) {
      integerValue(annotation.schemaVersion, "observation.annotation.schemaVersion", 1, 1);
    }
    if (annotation.confidence !== undefined) {
      numberValue(annotation.confidence, "observation.annotation.confidence", 0, 1);
    }
    if (annotation.provenance !== undefined) {
      requiredString(annotation.provenance, "observation.annotation.provenance", 160);
    }
    if (annotation.rationale !== undefined) {
      requiredString(annotation.rationale, "observation.annotation.rationale", 160);
    }
    if (annotation.reason !== undefined && annotation.reason !== null) {
      const reason = requiredString(annotation.reason, "observation.annotation.reason", 64);
      if (!attentionReasons.has(reason)) {
        throw new ValidationError(`unsupported observation attention reason: ${reason}`);
      }
    }
  }
  if (!Array.isArray(terminal.grid) || terminal.grid.length > 200) {
    throw new ValidationError("observation.terminal.grid must contain at most 200 lines");
  }
  const grid = terminal.grid.map((line, index) => {
    if (typeof line !== "string" || line.length > 1_024) {
      throw new ValidationError(`observation.terminal.grid[${index}] is invalid`);
    }
    return line;
  });
  if (terminal.styledGrid !== undefined && terminal.styledGrid !== null) {
    validateStyledGrid(terminal.styledGrid, grid.length);
  }

  const payloadJSON = JSON.stringify(observation);
  if (new TextEncoder().encode(payloadJSON).byteLength > maximumObservationBytes) {
    throw new ValidationError(`observation ${id} exceeds ${maximumObservationBytes} bytes`);
  }

  return {
    id,
    recordedAt: isoDate(observation.recordedAt, "observation.recordedAt"),
    event,
    label,
    harness: optionalString(session.harness, "observation.session.harness", 160),
    sessionID: requiredString(session.id, "observation.session.id", 160),
    runID: optionalString(session.runID, "observation.session.runID", 160),
    scenarioID: optionalString(observation.scenarioID, "observation.scenarioID", 160),
    checkpoint: optionalString(observation.checkpoint, "observation.checkpoint", 160),
    columns: integerValue(terminal.columns, "observation.terminal.columns", 1, 10_000),
    rows: integerValue(terminal.rows, "observation.terminal.rows", 1, 10_000),
    gridJSON: JSON.stringify(grid),
    activityState: requiredString(activity.state, "observation.activity.state", 100),
    activityEvidence: requiredString(activity.evidence, "observation.activity.evidence", 100),
    payloadJSON,
  };
}

export function parseObservationUpload(value: unknown): ObservationRecord[] {
  const upload = objectValue(value, "upload");
  if (!Array.isArray(upload.observations) || upload.observations.length === 0) {
    throw new ValidationError("upload.observations must be a non-empty array");
  }
  if (upload.observations.length > maximumUploadObservations) {
    throw new ValidationError(`upload contains more than ${maximumUploadObservations} observations`);
  }
  return upload.observations.map(parseObservation);
}

export function isAttentionLabel(value: string): boolean {
  return attentionLabels.has(value);
}

export function isUUID(value: string): boolean {
  return uuidPattern.test(value);
}

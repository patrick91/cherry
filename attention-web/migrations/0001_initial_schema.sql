PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS bundles (
    id TEXT PRIMARY KEY,
    source_host TEXT,
    source_created_at TEXT,
    expected_observations INTEGER NOT NULL CHECK (expected_observations >= 0),
    imported_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS observations (
    id TEXT PRIMARY KEY,
    first_bundle_id TEXT NOT NULL REFERENCES bundles(id),
    recorded_at TEXT NOT NULL,
    event TEXT NOT NULL,
    label TEXT,
    harness TEXT,
    session_id TEXT NOT NULL,
    run_id TEXT,
    scenario_id TEXT,
    checkpoint TEXT,
    columns_count INTEGER NOT NULL,
    rows_count INTEGER NOT NULL,
    grid_json TEXT NOT NULL,
    activity_state TEXT NOT NULL,
    activity_evidence TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    imported_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS observation_sources (
    observation_id TEXT NOT NULL REFERENCES observations(id) ON DELETE CASCADE,
    bundle_id TEXT NOT NULL REFERENCES bundles(id) ON DELETE CASCADE,
    PRIMARY KEY (observation_id, bundle_id)
);

CREATE INDEX IF NOT EXISTS idx_observations_recorded_at
    ON observations(recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_observations_harness_recorded_at
    ON observations(harness, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_observations_label_recorded_at
    ON observations(label, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_observations_session
    ON observations(session_id, recorded_at);
CREATE INDEX IF NOT EXISTS idx_observation_sources_bundle
    ON observation_sources(bundle_id);

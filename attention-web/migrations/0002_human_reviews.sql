PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS observation_reviews (
    observation_id TEXT PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('accepted', 'corrected', 'skipped')),
    label TEXT CHECK (label IN ('attention_needed', 'no_attention_needed', 'unknown')),
    reason TEXT CHECK (
        reason IS NULL
        OR reason IN ('result_ready', 'waiting_for_input', 'waiting_for_approval', 'blocked_or_error')
    ),
    reviewed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (
        (status = 'skipped' AND label IS NULL AND reason IS NULL)
        OR (status IN ('accepted', 'corrected') AND label IS NOT NULL)
    ),
    CHECK (
        status = 'skipped'
        OR (label = 'attention_needed' AND reason IS NOT NULL)
        OR (label IN ('no_attention_needed', 'unknown') AND reason IS NULL)
    )
);

CREATE INDEX IF NOT EXISTS idx_observation_reviews_status_reviewed_at
    ON observation_reviews(status, reviewed_at DESC);

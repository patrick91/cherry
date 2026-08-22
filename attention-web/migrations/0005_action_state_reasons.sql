PRAGMA foreign_keys = ON;

-- Reasons now describe both sides of the binary action decision. Keep NULL
-- no-action reasons valid for historical reviews recorded before this taxonomy.
CREATE TABLE observation_reviews_v2 (
    observation_id TEXT PRIMARY KEY REFERENCES observations(id) ON DELETE CASCADE,
    status TEXT NOT NULL CHECK (status IN ('accepted', 'corrected', 'skipped')),
    label TEXT CHECK (label IN ('attention_needed', 'no_attention_needed', 'unknown')),
    reason TEXT CHECK (
        reason IS NULL
        OR reason IN (
            'result_ready',
            'waiting_for_input',
            'waiting_for_approval',
            'blocked_or_error',
            'agent_working',
            'user_responding',
            'idle_no_active_task'
        )
    ),
    review_source TEXT NOT NULL DEFAULT 'human'
        CHECK (review_source IN ('human', 'assistant_audit')),
    reviewed_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (
        (status = 'skipped' AND label IS NULL AND reason IS NULL)
        OR (status IN ('accepted', 'corrected') AND label IS NOT NULL)
    ),
    CHECK (
        status = 'skipped'
        OR (
            label = 'attention_needed'
            AND reason IN (
                'result_ready',
                'waiting_for_input',
                'waiting_for_approval',
                'blocked_or_error'
            )
        )
        OR (
            label = 'no_attention_needed'
            AND (
                reason IS NULL
                OR reason IN ('agent_working', 'user_responding', 'idle_no_active_task')
            )
        )
        OR (label = 'unknown' AND reason IS NULL)
    )
);

INSERT INTO observation_reviews_v2
    (observation_id, status, label, reason, review_source, reviewed_at)
SELECT observation_id, status, label, reason, review_source, reviewed_at
FROM observation_reviews;

DROP TABLE observation_reviews;
ALTER TABLE observation_reviews_v2 RENAME TO observation_reviews;

CREATE INDEX idx_observation_reviews_status_reviewed_at
    ON observation_reviews(status, reviewed_at DESC);

-- Recover negative reasons where the old provisional-label pipeline already
-- recorded an equivalent rationale.
UPDATE observations
SET payload_json = json_set(
    payload_json,
    '$.annotation.reason',
    CASE json_extract(payload_json, '$.annotation.rationale')
        WHEN 'user_composing_at_prompt' THEN 'user_responding'
        WHEN 'active_working_indicator' THEN 'agent_working'
    END
)
WHERE label = 'no_attention_needed'
  AND json_extract(payload_json, '$.annotation.reason') IS NULL
  AND json_extract(payload_json, '$.annotation.rationale') IN (
      'user_composing_at_prompt',
      'active_working_indicator'
  );

UPDATE observation_reviews
SET reason = (
    SELECT json_extract(observations.payload_json, '$.annotation.reason')
    FROM observations
    WHERE observations.id = observation_reviews.observation_id
)
WHERE label = 'no_attention_needed'
  AND reason IS NULL
  AND observation_id IN (
      SELECT id
      FROM observations
      WHERE json_extract(payload_json, '$.annotation.reason') IN (
          'agent_working',
          'user_responding',
          'idle_no_active_task'
      )
  );

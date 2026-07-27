-- A visible draft means the user is already engaged with the prompt, so it is
-- a negative attention example rather than a request for another interruption.
UPDATE observations
SET label = 'no_attention_needed',
    payload_json = json_set(
        json_remove(payload_json, '$.annotation.reason'),
        '$.label', 'no_attention_needed',
        '$.annotation.schemaVersion', 1,
        '$.annotation.provenance', 'codex_transition_review',
        '$.annotation.confidence', 0.99,
        '$.annotation.rationale', 'user_composing_at_prompt'
    )
WHERE label IS NOT NULL
  AND event IN ('activity_state_changed', 'notification', 'input_changed')
  AND json_extract(payload_json, '$.interaction.hasUnsubmittedInput') = 1
  AND json_extract(payload_json, '$.annotation.provenance') = 'codex_transition_review';

-- Older bundles could label several working/idle transitions from one
-- composition episode. Keep the latest candidate in each five-second run.
-- Human-reviewed rows are never removed by this migration.
WITH composing AS (
    SELECT
        o.rowid AS observation_rowid,
        o.id,
        o.session_id,
        o.recorded_at,
        r.observation_id AS reviewed_observation_id,
        LEAD(o.recorded_at) OVER (
            PARTITION BY o.session_id
            ORDER BY o.recorded_at, o.rowid
        ) AS next_recorded_at
    FROM observations o
    LEFT JOIN observation_reviews r ON r.observation_id = o.id
    WHERE o.label = 'no_attention_needed'
      AND json_extract(o.payload_json, '$.annotation.rationale') = 'user_composing_at_prompt'
),
duplicates AS (
    SELECT id
    FROM composing
    WHERE reviewed_observation_id IS NULL
      AND next_recorded_at IS NOT NULL
      AND unixepoch(next_recorded_at) - unixepoch(recorded_at) BETWEEN 0 AND 5
)
UPDATE observations
SET label = NULL,
    payload_json = json_set(
        json_remove(payload_json, '$.annotation'),
        '$.label', NULL
    )
WHERE id IN (SELECT id FROM duplicates);

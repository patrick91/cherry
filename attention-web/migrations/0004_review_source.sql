ALTER TABLE observation_reviews
ADD COLUMN review_source TEXT NOT NULL DEFAULT 'human'
CHECK (review_source IN ('human', 'assistant_audit'));

-- This timestamp is the one conservative batch audit performed during the
-- initial local labeling pass. Keep those pseudo-labels available for
-- training, but never count them as manual evaluation truth.
UPDATE observation_reviews
SET review_source = 'assistant_audit'
WHERE reviewed_at = '2026-07-27 18:26:16';

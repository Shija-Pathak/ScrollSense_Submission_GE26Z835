PRAGMA foreign_keys = ON;

-- =====================================================================
-- Deliverable G.1: the external schema. One view per consumer in 2.6.
-- Each view is written so that its consumer never learns whether the
-- underlying state is an overwritten column, a validity interval or an
-- append-only log. Load after schema.sql and before queries.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- v_public_profile (mobile client)
-- Exposes handle, display name and follower count. Hides phone, email
-- (both live only in auth_identity, which this view never touches) and
-- account_state. Deactivated, pending-deletion and deleted accounts are
-- filtered out, so an account inside its deletion window is invisible.
-- Follower count = follow edges that are open right now.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_public_profile;
CREATE VIEW v_public_profile AS
SELECT u.user_id,
       u.handle,
       u.display_name,
       (SELECT count(*) FROM follow f
         WHERE f.followee_id = u.user_id AND f.ended_at IS NULL) AS follower_count
FROM app_user u
WHERE u.account_state = 'active';

-- ---------------------------------------------------------------------
-- v_video_current_state (Trust & Safety)
-- The moderation history is an append-only event log (B.2); the current
-- state is the newest decision per clip. A clip with no decision yet is
-- reported as 'pending', so every video appears exactly once.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_video_current_state;
CREATE VIEW v_video_current_state AS
SELECT v.video_id,
       coalesce(d.new_state, 'pending')        AS current_state,
       d.decided_at                            AS state_since,
       d.decided_by_kind                       AS decided_by,
       coalesce(ms.is_visible, 0)              AS is_visible,
       coalesce(ms.is_demoted, 0)              AS is_demoted
FROM video v
LEFT JOIN (
    SELECT video_id, new_state, decided_at, decided_by_kind
    FROM (
        SELECT video_id, new_state, decided_at, decided_by_kind,
               row_number() OVER (PARTITION BY video_id
                                  ORDER BY decided_at DESC, decision_id DESC) AS rn
        FROM moderation_decision
    )
    WHERE rn = 1
) d ON d.video_id = v.video_id
LEFT JOIN moderation_state ms ON ms.state_code = coalesce(d.new_state, 'pending');

-- ---------------------------------------------------------------------
-- v_creator_tier_current (Growth)
-- Tier history is kept as validity intervals (B.2). The current tier is
-- the interval that contains 'now'. A creator with no interval in force
-- is reported as 'none'.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_creator_tier_current;
CREATE VIEW v_creator_tier_current AS
SELECT c.creator_id,
       u.handle,
       coalesce(p.tier_code, 'none')           AS tier_code,
       coalesce(mt.tier_rank, 0)               AS tier_rank,
       p.valid_from                            AS tier_since
FROM creator c
JOIN app_user u ON u.user_id = c.creator_id
LEFT JOIN creator_tier_period p
       ON p.creator_id = c.creator_id
      AND p.valid_from <= strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
      AND (p.valid_to IS NULL OR p.valid_to > strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
LEFT JOIN monetisation_tier mt ON mt.tier_code = p.tier_code;

-- ---------------------------------------------------------------------
-- v_video_daily_engagement (Growth analysts)
-- Grain: one row per (video, calendar day on which it was shown).
-- Every quantity is attributed to the day of the impression, so a like
-- placed just after midnight still belongs to the impression that
-- produced it. Days with impressions and nothing else appear with zeros
-- because the impression day set is the driving table and every other
-- quantity is a LEFT JOIN onto it.
-- net_likes = likes minus retractions (an 'unlike' is its own row).
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_video_daily_engagement;
CREATE VIEW v_video_daily_engagement AS
WITH imp_day AS (
    SELECT impression_id, video_id, date(shown_at) AS day
    FROM impression
),
seg AS (
    SELECT impression_id,
           sum(watched_ms) AS watched_ms
    FROM view_segment
    GROUP BY impression_id
),
sig AS (
    SELECT impression_id,
           sum(kind = 'like')   AS likes,
           sum(kind = 'unlike') AS unlikes
    FROM engagement_signal
    GROUP BY impression_id
)
SELECT d.video_id,
       d.day,
       count(*)                                        AS impressions,
       count(seg.impression_id)                        AS views,
       round(coalesce(sum(seg.watched_ms), 0) / 1000.0, 1) AS watch_seconds,
       coalesce(sum(sig.likes), 0) - coalesce(sum(sig.unlikes), 0) AS net_likes
FROM imp_day d
LEFT JOIN seg ON seg.impression_id = d.impression_id
LEFT JOIN sig ON sig.impression_id = d.impression_id
GROUP BY d.video_id, d.day;

-- ---------------------------------------------------------------------
-- v_turn_cost (Finance)
-- Cost of each answered turn, priced at the rate that was in force when
-- the assistant responded, never the current rate. Rates are USD per
-- million tokens; cached input tokens are billed at the cached rate and
-- the remaining input tokens at the full rate. A turn whose model has no
-- price row covering its timestamp appears with NULL cost rather than
-- being silently dropped, so Finance can see the gap.
-- ---------------------------------------------------------------------
DROP VIEW IF EXISTS v_turn_cost;
CREATE VIEW v_turn_cost AS
SELECT m.turn_id,
       t.session_id,
       s.user_id,
       m.model_id,
       m.responded_at,
       m.input_tokens,
       m.cached_input_tokens,
       m.output_tokens,
       p.valid_from                                   AS price_valid_from,
       ((m.input_tokens - m.cached_input_tokens) * p.input_rate
        + m.cached_input_tokens * p.cached_input_rate
        + m.output_tokens * p.output_rate) / 1000000.0 AS cost_usd
FROM assistant_message m
JOIN agent_turn t ON t.turn_id = m.turn_id
JOIN agent_session s ON s.session_id = t.session_id
LEFT JOIN model_price p
       ON p.model_id = m.model_id
      AND p.valid_from <= m.responded_at
      AND (p.valid_to IS NULL OR p.valid_to > m.responded_at);

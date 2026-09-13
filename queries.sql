PRAGMA foreign_keys = ON;

-- =====================================================================
-- Deliverable F: thirteen queries. Roll number GE26Z835.
-- Load order: schema.sql, generate_data.py, views.sql, then this file.
-- Every timestamp in the database is ISO-8601 UTC text, so date(),
-- julianday() and strftime() apply directly and text comparison orders
-- correctly. "Now" is the latest impression in the data set
-- (2026-09-08T23:59:58Z) so the results are reproducible; each query
-- that needs it declares it in a CTE named ref.
-- Runtimes were measured with run_queries.py (Python sqlite3, warm
-- cache, no tuning) on SQLite 3.45.1.
-- Each block is one statement; the results block at the end of each
-- query was pasted in from the run.
-- =====================================================================


-- F1 · Top 10 audio tracks by number of distinct videos in the last 7 days.
-- Intent: "in the last 7 days" is read as clips uploaded in the seven days
--         ending at "now"; each clip counts once for its single track.
-- Expected shape: one row per track, at most 10; no fan-out because a
--         video carries at most one track.
WITH ref AS (SELECT max(shown_at) AS now_ts FROM impression)
SELECT t.track_id,
       t.title,
       t.kind,
       count(DISTINCT v.video_id) AS n_videos
FROM audio_track t
JOIN video v ON v.audio_track_id = t.track_id
CROSS JOIN ref
WHERE v.uploaded_at >= strftime('%Y-%m-%dT%H:%M:%SZ', ref.now_ts, '-7 days')
  AND v.uploaded_at <= ref.now_ts
GROUP BY t.track_id
ORDER BY n_videos DESC, t.track_id
LIMIT 10;
-- Rows returned: 10      Runtime: 51 ms
-- Reading: 619 clips were uploaded in the week and they used 168
-- different tracks, yet the top licensed track alone carries 74 of them
-- and the second 41: the short head and long tail the brief's "50,000
-- clips on one trending sound" implies.


-- F2 · Watch hours and completion rate per creator, live clips only.
-- Intent: every creator appears; creators with no live clips or never
--         watched show 0, not NULL, not absent. Completion rate = share of
--         impressions of live clips in which the end was reached at least
--         once (a creator shown 900 times and watched twice scores 2/900).
-- Expected shape: row count = number of creators (625). Watch time is
--         aggregated per impression first, then per creator, so a clip
--         with three segments cannot triple its impression count.
WITH live_video AS (
    SELECT v.video_id, v.owner_creator_id
    FROM video v
    JOIN v_video_current_state cs ON cs.video_id = v.video_id
    WHERE cs.current_state = 'live'
),
per_impression AS (
    SELECT i.impression_id,
           lv.owner_creator_id,
           coalesce(sum(s.watched_ms), 0)        AS watched_ms,
           max(coalesce(s.reached_end, 0))       AS completed
    FROM live_video lv
    JOIN impression i ON i.video_id = lv.video_id
    LEFT JOIN view_segment s ON s.impression_id = i.impression_id
    GROUP BY i.impression_id
)
SELECT c.creator_id,
       u.handle,
       count(p.impression_id)                                  AS live_impressions,
       round(coalesce(sum(p.watched_ms), 0) / 3600000.0, 3)   AS watch_hours,
       round(coalesce(avg(p.completed), 0.0), 4)               AS completion_rate
FROM creator c
JOIN app_user u ON u.user_id = c.creator_id
LEFT JOIN per_impression p ON p.owner_creator_id = c.creator_id
GROUP BY c.creator_id
ORDER BY watch_hours DESC, c.creator_id;
-- Rows returned: 625      Runtime: 1,056 ms
-- Reading: 625 rows = 625 creators, so nothing was dropped; the top
-- creator alone holds 53 of the 560 live watch hours, the mean completion
-- rate is under 5% because the denominator is impressions rather than
-- views, and the creator with no live impressions shows 0 hours and
-- completion 0 rather than being absent.


-- F3a · Videos with no audio track, written with NOT IN.
-- Intent: a video with audio_track_id NULL has no track.
-- Expected shape: with NOT IN the predicate NULL NOT IN (...) is NULL,
--         never TRUE, so this variant is expected to return zero rows.
SELECT v.video_id, v.audio_track_id
FROM video v
WHERE v.audio_track_id NOT IN (SELECT t.track_id FROM audio_track t);
-- Rows returned: 0      Runtime: 2 ms

-- F3b · The same question with NOT EXISTS.
-- Expected shape: one row per video whose audio_track_id is NULL (the FK
--         guarantees every non-NULL id exists), so the count equals
--         SELECT count(*) FROM video WHERE audio_track_id IS NULL.
SELECT v.video_id, v.audio_track_id
FROM video v
WHERE NOT EXISTS (SELECT 1 FROM audio_track t WHERE t.track_id = v.audio_track_id);
-- Rows returned: 7,321      Runtime: 7 ms
-- Reading: 0 versus 7,321. NOT IN evaluates x NOT IN (S) as
-- x <> s1 AND x <> s2 AND ...; when x is NULL every comparison is NULL,
-- the conjunction is NULL and the row fails the WHERE. NOT EXISTS asks
-- whether any track row matches, and NULL = track_id matches nothing, so
-- NOT EXISTS is TRUE for exactly the track-less videos. The same
-- collapse to zero rows happens if S contains a NULL (for example
-- SELECT origin_video_id FROM audio_track), which is why NOT IN is unsafe
-- against any nullable column on either side.


-- F4 · Users who liked and then retracted the like on the same clip within 60 seconds.
-- Intent: an 'unlike' row points at the like it retracts through
--         retracts_signal_id, and both rows sit on the same impression, so
--         "same clip, same user" is guaranteed by the schema rather than by
--         matching columns.
-- Expected shape: one row per retraction that happened within 60 s;
--         a user appears once per such pair.
SELECT i.user_id,
       u.handle,
       i.video_id,
       l.occurred_at AS liked_at,
       r.occurred_at AS retracted_at,
       CAST(round((julianday(r.occurred_at) - julianday(l.occurred_at)) * 86400) AS INTEGER) AS seconds_between
FROM engagement_signal r
JOIN engagement_signal l ON l.signal_id = r.retracts_signal_id
JOIN impression i        ON i.impression_id = l.impression_id
JOIN app_user u          ON u.user_id = i.user_id
WHERE r.kind = 'unlike'
  AND julianday(r.occurred_at) - julianday(l.occurred_at) <= 60.0 / 86400.0
ORDER BY seconds_between, liked_at;
-- Rows returned: 300      Runtime: 4 ms
-- Reading: 300 of 896 retractions (33%) happen within a minute, the
-- accidental-tap band that the ML team should treat differently from a
-- considered change of mind days later.


-- F5 · Videos whose caption carries the hashtag #study (case-insensitive,
--      tolerant of surrounding punctuation and whitespace).
-- Intent: lower-case the caption, turn the punctuation that can touch a
--         tag into spaces, pad with spaces, then look for ' #study ' with
--         instr(). trim() strips a leading '#' or spaces from the input
--         so '#Study', ' study ' and 'STUDY' all work. This matches the
--         whole tag only: #studytok does not match #study.
-- Expected shape: one row per video, no join, so no fan-out.
WITH norm AS (
    SELECT video_id,
           caption,
           ' ' || replace(replace(replace(replace(replace(replace(replace(
                 lower(caption), ',', ' '), '.', ' '), '!', ' '), '?', ' '),
                 ';', ' '), ':', ' '), char(10), ' ') || ' ' AS padded
    FROM video
)
SELECT video_id, caption
FROM norm
WHERE instr(padded, ' #' || lower(trim('#Study', ' #')) || ' ') > 0
ORDER BY video_id;
-- Rows returned: 727      Runtime: 38 ms
-- Reading: 727 clips carry #study as a whole tag; the same 727 comes
-- back from the normalised video_hashtag junction, which confirms the
-- string parsing, while a naive LIKE '%#study%' returns 1,370 because it
-- also matches #studytok. LIKE versus
-- GLOB: neither was used for the match itself, lower() plus instr() was,
-- and lower() folds ASCII only, exactly like LIKE. For a caption written
-- in Tamil the answer does not change because Tamil script has no case,
-- so the fold is a no-op and instr() still finds the tag byte for byte;
-- what would break it is a tag typed in a different Unicode normalisation
-- form, which no case fold repairs.


-- F6a · Users who were shown creator 2527's clips but never engaged with any of them.
-- Intent: set difference of two user sets: shown minus engaged. EXCEPT
--         removes duplicates, so the result is one row per user.
-- Expected shape: at most the number of distinct viewers of the creator.
SELECT i.user_id
FROM impression i
JOIN video v ON v.video_id = i.video_id
WHERE v.owner_creator_id = 2527
EXCEPT
SELECT i.user_id
FROM impression i
JOIN video v             ON v.video_id = i.video_id
JOIN engagement_signal s ON s.impression_id = i.impression_id
WHERE v.owner_creator_id = 2527;
-- Rows returned: 3,672      Runtime: 74 ms
-- Reading: 4,506 distinct users saw creator 2527's clips and 3,672 of
-- them (81%) never left a single explicit signal on any of them, the
-- leaky funnel the brief describes.

-- F6b · Signal roll-up with UNION: videos that received a like or a save.
-- Expected shape: one row per distinct video.
SELECT i.video_id FROM engagement_signal s JOIN impression i ON i.impression_id = s.impression_id WHERE s.kind = 'like'
UNION
SELECT i.video_id FROM engagement_signal s JOIN impression i ON i.impression_id = s.impression_id WHERE s.kind = 'save';
-- Rows returned: 5,190      Runtime: 17 ms

-- F6c · The same roll-up with UNION ALL.
-- Expected shape: one row per signal, duplicates kept.
SELECT i.video_id FROM engagement_signal s JOIN impression i ON i.impression_id = s.impression_id WHERE s.kind = 'like'
UNION ALL
SELECT i.video_id FROM engagement_signal s JOIN impression i ON i.impression_id = s.impression_id WHERE s.kind = 'save';
-- Rows returned: 10,045      Runtime: 16 ms
-- Reading: UNION returns 5,190 distinct videos; UNION ALL returns 10,045
-- rows, one per like plus one per save (8,153 likes + 1,892 saves).
-- UNION applies DISTINCT across the whole result, so a video liked
-- three times and saved once contributes one row; UNION ALL contributes
-- four. Use UNION ALL when the rows will be counted or summed afterwards.


-- F7 · Cost of each agent session last month (August 2026), broken out by
--      prompt template version, sessions costing more than USD 0.002.
-- Intent: v_turn_cost already prices every turn at the rate in force at
--         its timestamp; here it is summed per (session, template version).
--         The HAVING filter applies to the whole session's August cost,
--         so every version row of a qualifying session is shown.
-- Expected shape: one row per (session, template version) for sessions
--         over the threshold.
WITH session_cost AS (
    SELECT c.session_id, sum(c.cost_usd) AS session_usd
    FROM v_turn_cost c
    WHERE c.responded_at >= '2026-08-01T00:00:00Z'
      AND c.responded_at <  '2026-09-01T00:00:00Z'
    GROUP BY c.session_id
)
SELECT c.session_id,
       c.user_id,
       pt.name                          AS template,
       tv.version_no                    AS template_version,
       count(*)                         AS turns,
       round(sum(c.cost_usd), 6)        AS version_cost_usd,
       round(sc.session_usd, 6)         AS session_cost_usd
FROM v_turn_cost c
JOIN session_cost sc            ON sc.session_id = c.session_id
JOIN assistant_message m        ON m.turn_id = c.turn_id
JOIN prompt_template_version tv ON tv.template_version_id = m.template_version_id
JOIN prompt_template pt         ON pt.template_id = tv.template_id
WHERE c.responded_at >= '2026-08-01T00:00:00Z'
  AND c.responded_at <  '2026-09-01T00:00:00Z'
  AND sc.session_usd > 0.002
GROUP BY c.session_id, tv.template_version_id
ORDER BY sc.session_usd DESC, c.session_id, tv.version_no;
-- Rows returned: 32      Runtime: 6 ms
-- Reading: 32 of the 681 August sessions exceed USD 0.002, and none of
-- them straddles a template edit, so each appears once; the costliest
-- (0.0048 USD) ran on llama-3.1-70b at the price that took effect on
-- 1 August, which the view resolved from model_price rather than from
-- whatever the current row happens to say.


-- F8 · Videos whose moderation state changed more than twice, with the full
--      sequence of transitions in chronological order.
-- Intent: the first decision sets the initial state, so "changed more
--         than twice" means more than three decisions. group_concat with
--         ORDER BY (SQLite 3.44+) gives a defined order; on older versions
--         the order is undefined and the sequence would be silently wrong.
-- Expected shape: one row per qualifying video.
SELECT d.video_id,
       count(*) - 1                                         AS state_changes,
       group_concat(d.new_state, ' > ' ORDER BY d.decided_at, d.decision_id) AS transitions,
       min(d.decided_at)                                    AS first_decision,
       max(d.decided_at)                                    AS last_decision
FROM moderation_decision d
GROUP BY d.video_id
HAVING count(*) > 3
ORDER BY state_changes DESC, d.video_id;
-- Rows returned: 973      Runtime: 50 ms
-- Reading: 973 clips (5%) have three state changes; 562 of them were
-- demoted and later restored to live, 390 went pending > live > demoted
-- > taken_down, and 21 passed through age_restricted first.


-- F9 · Each user's longest streak of consecutive active days.
-- Intent: an active day is a calendar day with at least one impression
--         for the user. Gaps-and-islands: number the distinct days per
--         user; day minus row number is constant inside a run of
--         consecutive days, so grouping on it yields the streaks.
-- Expected shape: one row per user who has any impression.
WITH active_day AS (
    SELECT DISTINCT user_id, date(shown_at) AS day
    FROM impression
),
numbered AS (
    SELECT user_id, day,
           julianday(day) - row_number() OVER (PARTITION BY user_id ORDER BY day) AS island
    FROM active_day
),
streak AS (
    SELECT user_id, min(day) AS streak_start, max(day) AS streak_end, count(*) AS streak_days
    FROM numbered
    GROUP BY user_id, island
),
best AS (
    SELECT user_id, streak_start, streak_end, streak_days,
           row_number() OVER (PARTITION BY user_id ORDER BY streak_days DESC, streak_start) AS rn
    FROM streak
)
SELECT b.user_id, u.handle, b.streak_days AS longest_streak, b.streak_start, b.streak_end
FROM best b
JOIN app_user u ON u.user_id = b.user_id
WHERE b.rn = 1
ORDER BY longest_streak DESC, b.user_id;
-- Rows returned: 4,921      Runtime: 653 ms
-- Reading: 27 of the 4,921 users with any impression were active on all
-- 100 days of the window, while the median user's best run is 4 days,
-- the power-law activity profile the generator was asked to produce.


-- F10 · Creators ranked by 7-day rolling watch time as of "now", with
--       week-over-week change.
-- Intent: "7 days" means seven calendar days, not the last seven days on
--         which a creator happened to be active. A creator-by-day grid
--         (last 14 calendar days, every creator) is built first so that
--         days with no activity contribute zero and the RANGE frame over
--         julianday(day) covers exactly 6 preceding calendar days. The
--         previous week is the frame 13..7 days preceding.
-- Expected shape: one row per creator (625), including zero-watch creators.
WITH RECURSIVE ref AS (
    SELECT date(max(shown_at)) AS today FROM impression
),
days(day) AS (
    SELECT date(today, '-13 days') FROM ref
    UNION ALL
    SELECT date(day, '+1 day') FROM days WHERE day < (SELECT today FROM ref)
),
daily AS (
    SELECT v.owner_creator_id AS creator_id,
           date(i.shown_at)   AS day,
           sum(s.watched_ms)  AS watched_ms
    FROM view_segment s
    JOIN impression i ON i.impression_id = s.impression_id
    JOIN video v      ON v.video_id = i.video_id
    WHERE date(i.shown_at) >= (SELECT date(today, '-13 days') FROM ref)
    GROUP BY v.owner_creator_id, date(i.shown_at)
),
grid AS (
    SELECT c.creator_id, d.day, coalesce(dl.watched_ms, 0) AS watched_ms
    FROM creator c
    CROSS JOIN days d
    LEFT JOIN daily dl ON dl.creator_id = c.creator_id AND dl.day = d.day
),
rolling AS (
    SELECT creator_id, day,
           sum(watched_ms) OVER (PARTITION BY creator_id ORDER BY julianday(day)
                                 RANGE BETWEEN 6 PRECEDING AND CURRENT ROW)   AS this_week_ms,
           sum(watched_ms) OVER (PARTITION BY creator_id ORDER BY julianday(day)
                                 RANGE BETWEEN 13 PRECEDING AND 7 PRECEDING)  AS last_week_ms
    FROM grid
)
SELECT rank() OVER (ORDER BY r.this_week_ms DESC)          AS rnk,
       r.creator_id,
       u.handle,
       round(r.this_week_ms / 3600000.0, 2)                AS this_week_hours,
       round(r.last_week_ms / 3600000.0, 2)                AS last_week_hours,
       round((r.this_week_ms - r.last_week_ms) / 3600000.0, 2) AS wow_change_hours
FROM rolling r
JOIN app_user u ON u.user_id = r.creator_id
WHERE r.day = (SELECT today FROM ref)
ORDER BY rnk, r.creator_id;
-- Rows returned: 625      Runtime: 171 ms
-- Reading: the leader drew 11.1 watch hours this week against 0.1 last
-- week (a clip that took off), while the overall top creator sits second
-- with 9.5 hours; creators with zero hours in both weeks are still listed,
-- because the calendar grid, not the activity table, drives the query.


-- F11 · Full nesting tree of tool calls for agent session 1401, with depth.
-- Intent: start from the session's top-level calls (parent NULL) and
--         recurse down parent_call_id. A zero-padded path keeps siblings in
--         call order and children under their parent.
-- Expected shape: one row per tool call in the session; depth 1 = top level.
WITH RECURSIVE tree(call_id, turn_id, parent_call_id, tool_name, depth, path, latency_ms, errored) AS (
    SELECT tc.call_id, tc.turn_id, tc.parent_call_id, tc.tool_name, 1,
           printf('%03d.%03d', t.turn_index, tc.call_index), tc.latency_ms, tc.errored
    FROM tool_call tc
    JOIN agent_turn t ON t.turn_id = tc.turn_id
    WHERE t.session_id = 1401
      AND tc.parent_call_id IS NULL
    UNION ALL
    SELECT tc.call_id, tc.turn_id, tc.parent_call_id, tc.tool_name, tree.depth + 1,
           tree.path || '.' || printf('%03d', tc.call_index), tc.latency_ms, tc.errored
    FROM tool_call tc
    JOIN tree ON tc.parent_call_id = tree.call_id
)
SELECT t.turn_index,
       tree.depth,
       substr('..........', 1, (tree.depth - 1) * 2) || tree.tool_name AS call_tree,
       tree.call_id,
       tree.parent_call_id,
       tree.latency_ms,
       tree.errored
FROM tree
JOIN agent_turn t ON t.turn_id = tree.turn_id
ORDER BY tree.path;
-- Rows returned: 40      Runtime: 1 ms
-- Reading: four turns, 40 calls, nesting down to depth 6; the recursion
-- needed no depth limit because parent_call_id can only point inside the
-- same turn and the tree is finite by construction.


-- F12 · Sessions where the agent recommended a clip that the user then
--       watched to completion, with the clip's position in the shelf.
-- Intent: the thread is recommendation -> impression (recommendation_id)
--         -> view_segment (reached_end = 1). The impression's user must be
--         the session's user, which the schema guarantees through the
--         recommendation link but is asserted here as well.
-- Expected shape: one row per (recommendation, impression) that was
--         completed; a clip opened twice from the same shelf can appear
--         twice, with different impression ids.
SELECT s.session_id,
       s.user_id,
       t.turn_index,
       r.shelf_position,
       r.video_id,
       i.impression_id,
       sum(vs.watched_ms) / 1000.0     AS watch_seconds,
       v.duration_ms / 1000.0          AS clip_seconds
FROM recommendation r
JOIN agent_turn t     ON t.turn_id = r.turn_id
JOIN agent_session s  ON s.session_id = t.session_id
JOIN impression i     ON i.recommendation_id = r.recommendation_id
                     AND i.user_id = s.user_id
JOIN view_segment vs  ON vs.impression_id = i.impression_id
JOIN video v          ON v.video_id = r.video_id
GROUP BY i.impression_id
HAVING max(vs.reached_end) = 1
ORDER BY s.session_id, t.turn_index, r.shelf_position;
-- Rows returned: 311      Runtime: 449 ms
-- Reading: 311 of the 3,302 shelf clips that were opened (9%) were
-- watched to the end; positions 1 and 2 complete about three times as
-- often as position 7, and every row traces back to session, turn and
-- shelf slot without a single timestamp heuristic.


-- F13 · Turns where the LLM judge scored helpfulness above 4 but the user
--       gave a thumbs-down.
-- Intent: inner join of the two optional quality tables on turn_id; a
--         turn appears only if both mechanisms fired and they disagree.
-- Expected shape: a small number of rows, one per disagreeing turn.
-- Why this set matters commercially: the judge is the only quality
-- signal that exists at scale (27% of turns are judged, 4% are rated),
-- so every decision about templates and models is made on the judge's
-- word. These rows are the cases where a real user contradicts it. They
-- are the cheapest possible training and calibration data for the
-- judge itself, and each one is also a concrete complaint about the
-- explainer or the search shelf that a human can read.
SELECT j.turn_id,
       s.session_id,
       s.kind                    AS session_kind,
       j.helpfulness,
       j.groundedness,
       j.safety,
       r.rating                  AS user_rating,
       substr(t.user_message, 1, 40) AS user_message
FROM judge_score j
JOIN user_rating r    ON r.turn_id = j.turn_id
JOIN agent_turn t     ON t.turn_id = j.turn_id
JOIN agent_session s  ON s.session_id = t.session_id
WHERE j.helpfulness > 4
  AND r.rating = -1
ORDER BY j.helpfulness DESC, j.turn_id;
-- Rows returned: 6      Runtime: 0 ms
-- Reading: only 6 turns are both judged above 4 and thumbed down, which
-- is 4% of the 160 rated turns; small, but every one is a labelled
-- judge error.

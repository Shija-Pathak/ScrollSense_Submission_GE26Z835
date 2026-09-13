PRAGMA foreign_keys = ON;

-- =====================================================================
-- Deliverable G.3: three transaction scripts, each reproducing one of
-- the failure modes in Part I 2.7 and proving the database is
-- consistent afterwards. Roll number GE26Z835.
--
-- This file runs top to bottom on a single connection (for example
-- sqlite3 scrollsense.db < transactions.sql). The parts of T2 and T3
-- that need a second connection are marked "connection B"; they are
-- driven by run_transactions.py, which executes exactly the statements
-- shown here on two separate connections and prints the outcome.
-- Every script leaves the database as it found it.
-- =====================================================================


-- ---------------------------------------------------------------------
-- T1 · Like retraction must be atomic.
-- The founders' failure: the like row is ended but the negative signal
-- is never written (or the reverse). Both writes go in one transaction;
-- the third statement fails deliberately with OR ROLLBACK, which aborts
-- the whole transaction.
-- ---------------------------------------------------------------------

-- Pick a like that is still open. (The subquery is evaluated once and
-- reused below so the proof looks at the same row.)
CREATE TEMP TABLE t1_pick AS
SELECT signal_id, impression_id, occurred_at
FROM engagement_signal
WHERE kind = 'like' AND ended_at IS NULL
ORDER BY signal_id
LIMIT 1;

-- State before: like open, no retraction pointing at it.
SELECT 'T1 before' AS step,
       (SELECT ended_at FROM engagement_signal WHERE signal_id = (SELECT signal_id FROM t1_pick)) AS like_ended_at,
       (SELECT count(*) FROM engagement_signal WHERE retracts_signal_id = (SELECT signal_id FROM t1_pick)) AS retraction_rows;

BEGIN;
    -- write 1: end the like
    UPDATE engagement_signal
       SET ended_at = '2026-09-09T10:00:00Z'
     WHERE signal_id = (SELECT signal_id FROM t1_pick);

    -- write 2: record the retraction as its own negative signal
    INSERT INTO engagement_signal (impression_id, kind, occurred_at, retracts_signal_id)
    SELECT impression_id, 'unlike', '2026-09-09T10:00:00Z', signal_id FROM t1_pick;

    -- deliberate failure: a third write that violates a CHECK constraint
    -- (a share with no destination). OR ROLLBACK makes the constraint
    -- failure roll back the whole transaction, exactly as a killed
    -- process or dropped connection would (an uncommitted WAL frame is
    -- discarded on recovery). run_transactions.py also performs the
    -- crash variant: it closes the connection between the two writes.
    INSERT OR ROLLBACK INTO engagement_signal (impression_id, kind, occurred_at)
    SELECT impression_id, 'share', '2026-09-09T10:00:01Z' FROM t1_pick;
COMMIT;   -- never reached; the transaction was already rolled back

-- Proof of consistency: like still open AND no orphan retraction row.
-- Expect: like_ended_at NULL, retraction_rows 0, consistent = 1.
SELECT 'T1 after' AS step,
       (SELECT ended_at FROM engagement_signal WHERE signal_id = (SELECT signal_id FROM t1_pick)) AS like_ended_at,
       (SELECT count(*) FROM engagement_signal WHERE retracts_signal_id = (SELECT signal_id FROM t1_pick)) AS retraction_rows,
       ((SELECT ended_at IS NULL FROM engagement_signal WHERE signal_id = (SELECT signal_id FROM t1_pick))
        = (SELECT count(*) = 0 FROM engagement_signal WHERE retracts_signal_id = (SELECT signal_id FROM t1_pick))) AS consistent;

DROP TABLE t1_pick;


-- ---------------------------------------------------------------------
-- T2 · Moderation decision: a half-applied decision must be invisible.
-- In this design a decision is exactly one row in the append-only
-- moderation_decision table; the trigger trg_moderation_audit adds the
-- audit row in the same statement, and the current state is derived by
-- v_video_current_state, so there is no second "current state" write
-- that could be lost. The demonstration therefore shows that while the
-- decision is uncommitted on connection A, connection B (WAL mode) still
-- reads the previous state instead of blocking or seeing a partial row.
-- ---------------------------------------------------------------------

-- connection A: begin, append the decision, do not commit
BEGIN IMMEDIATE;
    INSERT INTO moderation_decision (video_id, new_state, decided_at, decided_by_kind, reviewer_user_id, reason)
    VALUES (1, 'taken_down', '2026-09-09T10:05:00Z', 'human',
            (SELECT user_id FROM app_user WHERE account_state = 'active' ORDER BY user_id LIMIT 1),
            'policy 4.2');
    -- connection A sees its own uncommitted write:
    SELECT 'T2 connection A (inside txn)' AS step, current_state FROM v_video_current_state WHERE video_id = 1;

    -- connection B (run from a second process while A is still open):
    --     SELECT current_state FROM v_video_current_state WHERE video_id = 1;
    -- Expect: the state before the decision ('live'), returned at once,
    -- because WAL readers see the last committed snapshot.
    --
    -- connection B, a write attempt while A holds the write lock
    -- (this is the second half of T3, see below):
    --     UPDATE app_user SET display_name = display_name WHERE user_id = 2;
    -- Expect: SQLITE_BUSY ("database is locked").

ROLLBACK;   -- the demonstration ends without applying the decision

-- Proof of consistency: the audit trail and the history agree, and video 1
-- is back to its committed state. Expect: decisions = audit rows, and
-- no 'taken_down' row dated 2026-09-09 exists.
SELECT 'T2 after' AS step,
       (SELECT current_state FROM v_video_current_state WHERE video_id = 1)          AS current_state,
       (SELECT count(*) FROM moderation_decision WHERE video_id = 1)                  AS decisions,
       (SELECT count(*) FROM moderation_audit WHERE video_id = 1)                     AS audit_rows,
       (SELECT count(*) FROM moderation_decision WHERE decided_at = '2026-09-09T10:05:00Z') AS leaked_rows;


-- ---------------------------------------------------------------------
-- T3 · Handle change, twice a year at most.
-- trg_handle_change_limit refuses a third change inside 365 days;
-- trg_handle_change_log records each successful one. The three attempts
-- run inside one transaction that is rolled back at the end, so the
-- database is unchanged afterwards.
-- ---------------------------------------------------------------------

BEGIN;
    -- a user with no handle changes in the last year
    CREATE TEMP TABLE t3_pick AS
    SELECT user_id, handle FROM app_user u
    WHERE account_state = 'active'
      AND NOT EXISTS (SELECT 1 FROM handle_change h
                      WHERE h.user_id = u.user_id
                        AND h.changed_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-365 days'))
    ORDER BY user_id LIMIT 1;

    SELECT 'T3 before' AS step, user_id, handle,
           (SELECT count(*) FROM handle_change WHERE user_id = t3_pick.user_id) AS changes_logged
    FROM t3_pick;

    -- attempt 1: allowed
    UPDATE app_user SET handle = 'ge26z835_first'  WHERE user_id = (SELECT user_id FROM t3_pick);
    -- attempt 2: allowed
    UPDATE app_user SET handle = 'ge26z835_second' WHERE user_id = (SELECT user_id FROM t3_pick);

    SELECT 'T3 after two changes' AS step, app_user.handle,
           (SELECT count(*) FROM handle_change WHERE user_id = t3_pick.user_id) AS changes_logged
    FROM app_user JOIN t3_pick USING (user_id);

    -- attempt 3: the trigger fires.
    -- Expect: Runtime error: handle may be changed at most twice per 365 days
    UPDATE app_user SET handle = 'ge26z835_third'  WHERE user_id = (SELECT user_id FROM t3_pick);

    -- Proof: the handle is still the second one and exactly two changes
    -- were logged; the failed statement changed nothing.
    SELECT 'T3 after third attempt' AS step, app_user.handle,
           (SELECT count(*) FROM handle_change WHERE user_id = t3_pick.user_id) AS changes_logged
    FROM app_user JOIN t3_pick USING (user_id);

    DROP TABLE t3_pick;
ROLLBACK;   -- leave the database as it was

-- Second connection (see run_transactions.py): while T2's transaction is
-- open on connection A, connection B runs
--     UPDATE app_user SET display_name = display_name WHERE user_id = 2;
-- and receives SQLITE_BUSY: "database is locked".
--
-- What it tells us: SQLite allows exactly one writer at a time, so two
-- transactions can never interleave their writes and it never has to
-- detect the lost update (two writers each reading the same row, then
-- both writing it, so the first write silently disappears). A
-- multi-writer engine prevents that anomaly with row locks or with
-- multi-version write-conflict detection; SQLite simply never lets the
-- second writer start.

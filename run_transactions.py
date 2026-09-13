"""
Drives the three transaction demonstrations in transactions.sql,
including the parts that need two connections to the same database
file. Prints what each connection sees. Leaves the database unchanged.
"""

import sqlite3

DB_PATH = "scrollsense.db"


def connect(timeout=0.0):
    con = sqlite3.connect(DB_PATH, timeout=timeout, isolation_level=None)  # autocommit; we issue BEGIN ourselves
    con.execute("PRAGMA foreign_keys = ON")
    return con


def like_state(con, signal_id):
    ended = con.execute("SELECT ended_at FROM engagement_signal WHERE signal_id = ?", (signal_id,)).fetchone()[0]
    retractions = con.execute("SELECT count(*) FROM engagement_signal WHERE retracts_signal_id = ?", (signal_id,)).fetchone()[0]
    return ended, retractions


def t1():
    print("=" * 70)
    print("T1  Like retraction is atomic")
    con = connect()
    signal_id, impression_id = con.execute(
        "SELECT signal_id, impression_id FROM engagement_signal WHERE kind = 'like' AND ended_at IS NULL ORDER BY signal_id LIMIT 1"
    ).fetchone()
    print(f"  like {signal_id}: before  ended_at={like_state(con, signal_id)[0]!r} retraction_rows={like_state(con, signal_id)[1]}")

    # Variant A: constraint failure with OR ROLLBACK (as in transactions.sql)
    con.execute("BEGIN")
    con.execute("UPDATE engagement_signal SET ended_at = '2026-09-09T10:00:00Z' WHERE signal_id = ?", (signal_id,))
    con.execute("INSERT INTO engagement_signal (impression_id, kind, occurred_at, retracts_signal_id) VALUES (?, 'unlike', '2026-09-09T10:00:00Z', ?)",
                (impression_id, signal_id))
    try:
        con.execute("INSERT OR ROLLBACK INTO engagement_signal (impression_id, kind, occurred_at) VALUES (?, 'share', '2026-09-09T10:00:01Z')",
                    (impression_id,))
    except sqlite3.IntegrityError as e:
        print(f"  deliberate failure raised: {e}")
    print(f"  in transaction? {con.in_transaction}  (False = rolled back by OR ROLLBACK)")
    ended, retractions = like_state(con, signal_id)
    print(f"  after variant A: ended_at={ended!r} retraction_rows={retractions}  consistent={(ended is None) == (retractions == 0)}")

    # Variant B: process dies between the two writes (connection dropped, no COMMIT)
    con.execute("BEGIN")
    con.execute("UPDATE engagement_signal SET ended_at = '2026-09-09T10:00:00Z' WHERE signal_id = ?", (signal_id,))
    print("  variant B: first write done, connection now closed without COMMIT (simulated crash)")
    con.close()
    con = connect()
    ended, retractions = like_state(con, signal_id)
    print(f"  after variant B: ended_at={ended!r} retraction_rows={retractions}  consistent={(ended is None) == (retractions == 0)}")
    con.close()


def t2_and_t3_busy():
    print("=" * 70)
    print("T2  Half-applied moderation decision is invisible to a second connection")
    a = connect()
    b = connect(timeout=0.0)
    before = b.execute("SELECT current_state FROM v_video_current_state WHERE video_id = 1").fetchone()[0]
    reviewer = a.execute("SELECT user_id FROM app_user WHERE account_state = 'active' ORDER BY user_id LIMIT 1").fetchone()[0]
    print(f"  video 1 committed state: {before}")
    a.execute("BEGIN IMMEDIATE")
    a.execute("INSERT INTO moderation_decision (video_id, new_state, decided_at, decided_by_kind, reviewer_user_id, reason) "
              "VALUES (1, 'taken_down', '2026-09-09T10:05:00Z', 'human', ?, 'policy 4.2')", (reviewer,))
    inside = a.execute("SELECT current_state FROM v_video_current_state WHERE video_id = 1").fetchone()[0]
    print(f"  connection A inside its open transaction sees: {inside}")
    seen_by_b = b.execute("SELECT current_state FROM v_video_current_state WHERE video_id = 1").fetchone()[0]
    print(f"  connection B, while A is uncommitted, sees:     {seen_by_b}  (WAL snapshot; no blocking)")
    audit_b = b.execute("SELECT count(*) FROM moderation_audit WHERE video_id = 1").fetchone()[0]
    hist_b = b.execute("SELECT count(*) FROM moderation_decision WHERE video_id = 1").fetchone()[0]
    print(f"  connection B: history rows={hist_b} audit rows={audit_b} (agree: {hist_b == audit_b})")

    print("-" * 70)
    print("T3b Write attempt from connection B while A still holds the write lock")
    try:
        b.execute("UPDATE app_user SET display_name = display_name WHERE user_id = 2")
        print("  unexpected: the write succeeded")
    except sqlite3.OperationalError as e:
        print(f"  connection B got: sqlite3.OperationalError: {e}  (SQLITE_BUSY)")
    a.execute("ROLLBACK")
    after = b.execute("SELECT current_state FROM v_video_current_state WHERE video_id = 1").fetchone()[0]
    leaked = b.execute("SELECT count(*) FROM moderation_decision WHERE decided_at = '2026-09-09T10:05:00Z'").fetchone()[0]
    print(f"  after A rolled back: video 1 state={after}, leaked rows={leaked}")
    a.close()
    b.close()


def t3_handle_rule():
    print("=" * 70)
    print("T3a Handle may change at most twice per 365 days")
    con = connect()
    con.execute("BEGIN")
    user_id, handle = con.execute(
        "SELECT user_id, handle FROM app_user u WHERE account_state = 'active' AND NOT EXISTS ("
        "SELECT 1 FROM handle_change h WHERE h.user_id = u.user_id AND h.changed_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-365 days')) "
        "ORDER BY user_id LIMIT 1").fetchone()
    print(f"  user {user_id} starts as {handle!r}")
    for attempt, new in enumerate(["ge26z835_first", "ge26z835_second", "ge26z835_third"], start=1):
        try:
            con.execute("UPDATE app_user SET handle = ? WHERE user_id = ?", (new, user_id))
            n = con.execute("SELECT count(*) FROM handle_change WHERE user_id = ?", (user_id,)).fetchone()[0]
            print(f"  attempt {attempt}: ok, handle={new!r}, changes logged={n}")
        except sqlite3.IntegrityError as e:
            cur = con.execute("SELECT handle FROM app_user WHERE user_id = ?", (user_id,)).fetchone()[0]
            n = con.execute("SELECT count(*) FROM handle_change WHERE user_id = ?", (user_id,)).fetchone()[0]
            print(f"  attempt {attempt}: refused: {e}; handle still {cur!r}, changes logged={n}")
    con.execute("ROLLBACK")
    print(f"  rolled back; handle is {con.execute('SELECT handle FROM app_user WHERE user_id = ?', (user_id,)).fetchone()[0]!r} again")
    con.close()


if __name__ == "__main__":
    t1()
    t2_and_t3_busy()
    t3_handle_rule()

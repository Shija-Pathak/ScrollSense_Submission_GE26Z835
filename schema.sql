PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;



CREATE TABLE moderation_state (
    state_code   TEXT PRIMARY KEY,
    is_visible   INTEGER NOT NULL CHECK (is_visible IN (0, 1)),
    is_demoted   INTEGER NOT NULL CHECK (is_demoted IN (0, 1)),
    description  TEXT NOT NULL
);

INSERT INTO moderation_state VALUES
    ('pending',        0, 0, 'Uploaded, not yet classified'),
    ('live',           1, 0, 'Visible in the feed'),
    ('age_restricted', 1, 0, 'Visible only to adult accounts'),
    ('demoted',        1, 1, 'Visible but surfaced less often'),
    ('taken_down',     0, 0, 'Removed from the feed');

CREATE TABLE monetisation_tier (
    tier_code   TEXT PRIMARY KEY,
    tier_rank   INTEGER NOT NULL UNIQUE CHECK (tier_rank >= 0),
    description TEXT NOT NULL
);

INSERT INTO monetisation_tier VALUES
    ('none',     0, 'Not monetised'),
    ('bronze',   1, 'Entry tier'),
    ('silver',   2, 'Mid tier'),
    ('gold',     3, 'Top tier'),
    ('partner',  4, 'Managed partner programme');

CREATE TABLE share_destination (
    destination_code TEXT PRIMARY KEY,
    label            TEXT NOT NULL
);

INSERT INTO share_destination VALUES
    ('whatsapp',  'WhatsApp'),
    ('instagram', 'Instagram'),
    ('copy_link', 'Copied link');

CREATE TABLE interest_category (
    category_id INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE CHECK (name = lower(trim(name)) AND length(name) BETWEEN 2 AND 40)
);


CREATE TABLE app_user (
    user_id               INTEGER PRIMARY KEY,
    handle                TEXT NOT NULL COLLATE NOCASE UNIQUE
                          CHECK (handle = trim(handle)
                                 AND length(handle) BETWEEN 3 AND 30
                                 AND handle NOT GLOB '*[^A-Za-z0-9_.]*'),
    display_name          TEXT NOT NULL CHECK (length(display_name) BETWEEN 1 AND 60),
    account_state         TEXT NOT NULL DEFAULT 'active'
                          CHECK (account_state IN ('active', 'deactivated', 'pending_deletion', 'deleted')),
    deletion_requested_at TEXT
                          CHECK (deletion_requested_at IS NULL OR deletion_requested_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    created_at            TEXT NOT NULL
                          CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
\
    CHECK ((account_state IN ('pending_deletion', 'deleted')) = (deletion_requested_at IS NOT NULL))
);

CREATE TABLE auth_identity (
    identity_id      INTEGER PRIMARY KEY,
    user_id          INTEGER NOT NULL
                     REFERENCES app_user(user_id) ON DELETE CASCADE,   
    provider         TEXT NOT NULL CHECK (provider IN ('phone', 'google')),
    provider_subject TEXT NOT NULL CHECK (length(provider_subject) BETWEEN 5 AND 254),
    verified_at      TEXT NOT NULL,
    UNIQUE (provider, provider_subject),   
    UNIQUE (user_id, provider)             
);


CREATE TABLE handle_change (
    change_id  INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL
               REFERENCES app_user(user_id) ON DELETE CASCADE,   
    old_handle TEXT NOT NULL,
    new_handle TEXT NOT NULL,
    changed_at TEXT NOT NULL
               CHECK (changed_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    CHECK (old_handle <> new_handle COLLATE NOCASE)
);


CREATE TABLE user_declared_interest (
    user_id     INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE CASCADE,          
    category_id INTEGER NOT NULL REFERENCES interest_category(category_id) ON DELETE RESTRICT, 
    declared_at TEXT NOT NULL,
    PRIMARY KEY (user_id, category_id)
);

CREATE TABLE inferred_interest_score (
    user_id     INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE CASCADE,          -- derived data dies with the account
    category_id INTEGER NOT NULL REFERENCES interest_category(category_id) ON DELETE RESTRICT,
    scored_at   TEXT NOT NULL
                CHECK (scored_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    confidence  REAL NOT NULL CHECK (confidence >= 0.0 AND confidence <= 1.0),
    PRIMARY KEY (user_id, category_id, scored_at)
) WITHOUT ROWID;


CREATE TABLE inferred_interest_suppression (
    user_id       INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE CASCADE,
    category_id   INTEGER NOT NULL REFERENCES interest_category(category_id) ON DELETE RESTRICT,
    suppressed_at TEXT NOT NULL,
    lifted_at     TEXT CHECK (lifted_at IS NULL OR lifted_at > suppressed_at),
    PRIMARY KEY (user_id, category_id, suppressed_at)
) WITHOUT ROWID;


CREATE TABLE creator (
    creator_id        INTEGER PRIMARY KEY
                      REFERENCES app_user(user_id) ON DELETE RESTRICT,  
    became_creator_at TEXT NOT NULL
);


CREATE TABLE creator_tier_period (
    creator_id INTEGER NOT NULL REFERENCES creator(creator_id) ON DELETE RESTRICT,   
    tier_code  TEXT NOT NULL REFERENCES monetisation_tier(tier_code) ON DELETE RESTRICT,
    valid_from TEXT NOT NULL
               CHECK (valid_from GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    valid_to   TEXT CHECK (valid_to IS NULL OR valid_to > valid_from),
    PRIMARY KEY (creator_id, valid_from)
) WITHOUT ROWID;


CREATE TABLE audio_track (
    track_id              INTEGER PRIMARY KEY,
    title                 TEXT NOT NULL CHECK (length(title) BETWEEN 1 AND 120),
    kind                  TEXT NOT NULL CHECK (kind IN ('original', 'licensed')),
    origin_video_id       INTEGER
                          REFERENCES video(video_id) ON DELETE SET NULL  
                          DEFERRABLE INITIALLY DEFERRED,
    licence_catalogue_ref TEXT CHECK (licence_catalogue_ref IS NULL OR length(licence_catalogue_ref) BETWEEN 3 AND 60),
    created_at            TEXT NOT NULL,
   
    CHECK ((kind = 'licensed') = (licence_catalogue_ref IS NOT NULL)),
    CHECK (kind = 'original' OR origin_video_id IS NULL)
);


CREATE TABLE video (
    video_id         INTEGER PRIMARY KEY,
    owner_creator_id INTEGER NOT NULL REFERENCES creator(creator_id) ON DELETE RESTRICT,   
    duration_ms      INTEGER NOT NULL CHECK (typeof(duration_ms) = 'integer' AND duration_ms BETWEEN 20000 AND 90000),
    caption          TEXT NOT NULL CHECK (length(caption) <= 2200),
    audio_track_id   INTEGER
                     REFERENCES audio_track(track_id) ON DELETE SET NULL,  
    uploaded_at      TEXT NOT NULL
                     CHECK (uploaded_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
);

CREATE INDEX ix_video_owner ON video(owner_creator_id);
CREATE INDEX ix_video_audio ON video(audio_track_id);


CREATE TABLE hashtag (
    hashtag_id INTEGER PRIMARY KEY,
    tag        TEXT NOT NULL UNIQUE
               CHECK (tag = lower(tag) AND length(tag) BETWEEN 1 AND 100 AND tag NOT GLOB '*[^a-z0-9_]*')
);


CREATE TABLE video_hashtag (
    video_id   INTEGER NOT NULL REFERENCES video(video_id) ON DELETE CASCADE,     
    hashtag_id INTEGER NOT NULL REFERENCES hashtag(hashtag_id) ON DELETE CASCADE, 
    position   INTEGER NOT NULL CHECK (position >= 1),
    PRIMARY KEY (video_id, hashtag_id),
    UNIQUE (video_id, position)
) WITHOUT ROWID;


CREATE TABLE moderation_decision (
    decision_id        INTEGER PRIMARY KEY,
    video_id           INTEGER NOT NULL REFERENCES video(video_id) ON DELETE RESTRICT,   
    new_state          TEXT NOT NULL REFERENCES moderation_state(state_code) ON DELETE RESTRICT,
    decided_at         TEXT NOT NULL
                       CHECK (decided_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    decided_by_kind    TEXT NOT NULL CHECK (decided_by_kind IN ('classifier', 'human')),
    classifier_version TEXT,
    reviewer_user_id   INTEGER REFERENCES app_user(user_id) ON DELETE RESTRICT,
    reason             TEXT,

    CHECK ((decided_by_kind = 'classifier') = (classifier_version IS NOT NULL)),
    CHECK ((decided_by_kind = 'human') = (reviewer_user_id IS NOT NULL)),
    UNIQUE (video_id, decided_at)
);


CREATE TABLE follow (
    follower_id INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    followee_id INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    started_at  TEXT NOT NULL
                CHECK (started_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    ended_at    TEXT CHECK (ended_at IS NULL OR ended_at >= started_at),
    end_reason  TEXT CHECK (end_reason IS NULL OR end_reason IN ('unfollow', 'block')),
    PRIMARY KEY (follower_id, followee_id, started_at),
    CHECK (follower_id <> followee_id),
    CHECK ((ended_at IS NULL) = (end_reason IS NULL))
) WITHOUT ROWID;

CREATE INDEX ix_follow_followee ON follow(followee_id, ended_at);


CREATE TABLE block (
    blocker_id INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    blocked_id INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    started_at TEXT NOT NULL,
    ended_at   TEXT CHECK (ended_at IS NULL OR ended_at >= started_at),
    PRIMARY KEY (blocker_id, blocked_id, started_at),
    CHECK (blocker_id <> blocked_id)
) WITHOUT ROWID;


CREATE TABLE mute (
    muter_id   INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    muted_id   INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    started_at TEXT NOT NULL,
    ended_at   TEXT CHECK (ended_at IS NULL OR ended_at >= started_at),
    PRIMARY KEY (muter_id, muted_id, started_at),
    CHECK (muter_id <> muted_id)
) WITHOUT ROWID;


CREATE TABLE llm_model (
    model_id    INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    vendor      TEXT NOT NULL,
    is_internal INTEGER NOT NULL CHECK (is_internal IN (0, 1))
);


CREATE TABLE model_price (
    model_id          INTEGER NOT NULL REFERENCES llm_model(model_id) ON DELETE RESTRICT,   -- costs already reported depend on it
    valid_from        TEXT NOT NULL
                      CHECK (valid_from GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    valid_to          TEXT CHECK (valid_to IS NULL OR valid_to > valid_from),
    input_rate        REAL NOT NULL CHECK (input_rate >= 0),
    output_rate       REAL NOT NULL CHECK (output_rate >= 0),
    cached_input_rate REAL NOT NULL CHECK (cached_input_rate >= 0 AND cached_input_rate <= input_rate),
    PRIMARY KEY (model_id, valid_from)
) WITHOUT ROWID;


CREATE TABLE prompt_template (
    template_id INTEGER PRIMARY KEY,
    name        TEXT NOT NULL UNIQUE,
    purpose     TEXT NOT NULL CHECK (purpose IN ('explainer', 'search'))
);


CREATE TABLE prompt_template_version (
    template_version_id INTEGER PRIMARY KEY,
    template_id         INTEGER NOT NULL REFERENCES prompt_template(template_id) ON DELETE RESTRICT,   -- historical responses point here
    version_no          INTEGER NOT NULL CHECK (version_no >= 1),
    body_text           TEXT NOT NULL CHECK (length(body_text) >= 1),
    created_at          TEXT NOT NULL,
    UNIQUE (template_id, version_no)
);


CREATE TABLE agent_session (
    session_id            INTEGER PRIMARY KEY,
    user_id               INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT,
    kind                  TEXT NOT NULL CHECK (kind IN ('why_this', 'search')),
    trigger_impression_id INTEGER
                          REFERENCES impression(impression_id) ON DELETE RESTRICT
                          DEFERRABLE INITIALLY DEFERRED,
    started_at            TEXT NOT NULL
                          CHECK (started_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    ended_at              TEXT CHECK (ended_at IS NULL OR ended_at >= started_at),
    CHECK ((kind = 'why_this') = (trigger_impression_id IS NOT NULL))
);

CREATE INDEX ix_session_user ON agent_session(user_id, started_at);


CREATE TABLE agent_turn (
    turn_id      INTEGER PRIMARY KEY,
    session_id   INTEGER NOT NULL REFERENCES agent_session(session_id) ON DELETE CASCADE,   -- turns are existence-dependent on the session
    turn_index   INTEGER NOT NULL CHECK (turn_index >= 1),
    user_message TEXT NOT NULL CHECK (length(user_message) BETWEEN 1 AND 4000),
    created_at   TEXT NOT NULL
                 CHECK (created_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    UNIQUE (session_id, turn_index)
);


CREATE TABLE assistant_message (
    turn_id             INTEGER PRIMARY KEY REFERENCES agent_turn(turn_id) ON DELETE CASCADE,   -- part of the turn
    template_version_id INTEGER NOT NULL REFERENCES prompt_template_version(template_version_id) ON DELETE RESTRICT,
    model_id            INTEGER NOT NULL REFERENCES llm_model(model_id) ON DELETE RESTRICT,
    temperature         REAL NOT NULL CHECK (temperature >= 0.0 AND temperature <= 2.0),
    content             TEXT NOT NULL,
    input_tokens        INTEGER NOT NULL CHECK (input_tokens >= 0),
    output_tokens       INTEGER NOT NULL CHECK (output_tokens >= 0),
    cached_input_tokens INTEGER NOT NULL CHECK (cached_input_tokens >= 0 AND cached_input_tokens <= input_tokens),
    latency_ms          INTEGER NOT NULL CHECK (latency_ms >= 0),
    responded_at        TEXT NOT NULL
                        CHECK (responded_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z')
);

CREATE INDEX ix_assistant_model_time ON assistant_message(model_id, responded_at);


CREATE TABLE tool_call (
    call_id        INTEGER PRIMARY KEY,
    turn_id        INTEGER NOT NULL REFERENCES agent_turn(turn_id) ON DELETE CASCADE,   -- calls belong to the turn
    parent_call_id INTEGER REFERENCES tool_call(call_id) ON DELETE CASCADE,            -- a subtree cannot outlive its parent
    call_index     INTEGER NOT NULL CHECK (call_index >= 1),
    tool_name      TEXT NOT NULL CHECK (tool_name IN ('search_videos', 'get_user_history', 'fetch_trending_audio', 'rerank', 'lookup_creator')),
    arguments_json TEXT NOT NULL CHECK (json_valid(arguments_json)),
    result_summary TEXT,
    latency_ms     INTEGER NOT NULL CHECK (latency_ms >= 0),
    errored        INTEGER NOT NULL CHECK (errored IN (0, 1)),
    error_message  TEXT,
    started_at     TEXT NOT NULL,
    CHECK ((errored = 1) = (error_message IS NOT NULL)),
    CHECK (errored = 1 OR result_summary IS NOT NULL),
    CHECK (parent_call_id IS NULL OR parent_call_id <> call_id)
);

CREATE INDEX ix_tool_call_turn ON tool_call(turn_id);
CREATE INDEX ix_tool_call_parent ON tool_call(parent_call_id);


CREATE TABLE recommendation (
    recommendation_id INTEGER PRIMARY KEY,
    turn_id           INTEGER NOT NULL REFERENCES assistant_message(turn_id) ON DELETE CASCADE,   -- a shelf is part of its reply
    shelf_position    INTEGER NOT NULL CHECK (shelf_position BETWEEN 1 AND 20),
    video_id          INTEGER NOT NULL REFERENCES video(video_id) ON DELETE RESTRICT,   -- what was recommended must stay traceable
    UNIQUE (turn_id, shelf_position),
    UNIQUE (turn_id, video_id)
);

CREATE TABLE judge_score (
    turn_id        INTEGER PRIMARY KEY REFERENCES assistant_message(turn_id) ON DELETE CASCADE,
    judge_model_id INTEGER NOT NULL REFERENCES llm_model(model_id) ON DELETE RESTRICT,
    helpfulness    REAL NOT NULL CHECK (helpfulness BETWEEN 0 AND 5),
    groundedness   REAL NOT NULL CHECK (groundedness BETWEEN 0 AND 5),
    safety         REAL NOT NULL CHECK (safety BETWEEN 0 AND 5),
    judged_at      TEXT NOT NULL
);


CREATE TABLE user_rating (
    turn_id  INTEGER PRIMARY KEY REFERENCES assistant_message(turn_id) ON DELETE CASCADE,
    rating   INTEGER NOT NULL CHECK (rating IN (-1, 1)),  
    rated_at TEXT NOT NULL
);


CREATE TABLE ranker_version (
    ranker_version_id INTEGER PRIMARY KEY,
    name              TEXT NOT NULL UNIQUE,
    deployed_at       TEXT NOT NULL
);


CREATE TABLE impression (
    impression_id     INTEGER PRIMARY KEY,
    user_id           INTEGER NOT NULL REFERENCES app_user(user_id) ON DELETE RESTRICT, 
    video_id          INTEGER NOT NULL REFERENCES video(video_id) ON DELETE RESTRICT,
    shown_at          TEXT NOT NULL
                      CHECK (shown_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    feed_position     INTEGER NOT NULL CHECK (feed_position >= 1),
    ranker_version_id INTEGER NOT NULL REFERENCES ranker_version(ranker_version_id) ON DELETE RESTRICT,
    recommendation_id INTEGER
                      REFERENCES recommendation(recommendation_id) ON DELETE SET NULL,  
    UNIQUE (user_id, video_id, shown_at)
);

CREATE INDEX ix_impression_video_time ON impression(video_id, shown_at);
CREATE INDEX ix_impression_user_time ON impression(user_id, shown_at);
CREATE INDEX ix_impression_recommendation ON impression(recommendation_id);


CREATE TABLE view_segment (
    impression_id INTEGER NOT NULL REFERENCES impression(impression_id) ON DELETE CASCADE, 
    segment_index INTEGER NOT NULL CHECK (segment_index >= 1),
    started_at    TEXT NOT NULL
                  CHECK (started_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    watched_ms    INTEGER NOT NULL CHECK (watched_ms >= 300),  
    reached_end   INTEGER NOT NULL CHECK (reached_end IN (0, 1)),
    PRIMARY KEY (impression_id, segment_index)
) WITHOUT ROWID;

CREATE TABLE engagement_signal (
    signal_id             INTEGER PRIMARY KEY,
    impression_id         INTEGER NOT NULL REFERENCES impression(impression_id) ON DELETE RESTRICT,  
    kind                  TEXT NOT NULL CHECK (kind IN ('like', 'unlike', 'save', 'share', 'comment', 'follow', 'not_interested', 'report')),
    occurred_at           TEXT NOT NULL
                          CHECK (occurred_at GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z'),
    share_destination_code TEXT REFERENCES share_destination(destination_code) ON DELETE RESTRICT,
    retracts_signal_id    INTEGER REFERENCES engagement_signal(signal_id) ON DELETE RESTRICT,
    ended_at              TEXT CHECK (ended_at IS NULL OR ended_at >= occurred_at),
    report_reason         TEXT,
    CHECK ((kind = 'share') = (share_destination_code IS NOT NULL)),
    CHECK ((kind = 'unlike') = (retracts_signal_id IS NOT NULL)),
    CHECK ((kind = 'report') = (report_reason IS NOT NULL)),
    CHECK (ended_at IS NULL OR kind = 'like'),
    UNIQUE (retracts_signal_id)
);

CREATE INDEX ix_signal_impression ON engagement_signal(impression_id, kind);
CREATE INDEX ix_signal_time ON engagement_signal(occurred_at);


CREATE TABLE comment (
    signal_id  INTEGER PRIMARY KEY REFERENCES engagement_signal(signal_id) ON DELETE CASCADE,   -- body is part of the signal
    body       TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
    removed_at TEXT   
);


CREATE TRIGGER trg_handle_change_limit
BEFORE UPDATE OF handle ON app_user
FOR EACH ROW
WHEN NEW.handle <> OLD.handle COLLATE NOCASE
BEGIN
    SELECT RAISE(ABORT, 'handle may be changed at most twice per 365 days')
    WHERE (SELECT count(*) FROM handle_change
           WHERE user_id = OLD.user_id
             AND changed_at > strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-365 days')) >= 2;
END;

CREATE TRIGGER trg_handle_change_log
AFTER UPDATE OF handle ON app_user
FOR EACH ROW
WHEN NEW.handle <> OLD.handle COLLATE NOCASE
BEGIN
    INSERT INTO handle_change (user_id, old_handle, new_handle, changed_at)
    VALUES (OLD.user_id, OLD.handle, NEW.handle, strftime('%Y-%m-%dT%H:%M:%SZ', 'now'));
END;


CREATE TRIGGER trg_block_breaks_follow
AFTER INSERT ON block
FOR EACH ROW
BEGIN
    UPDATE follow
       SET ended_at = NEW.started_at, end_reason = 'block'
     WHERE ended_at IS NULL
       AND ((follower_id = NEW.blocker_id AND followee_id = NEW.blocked_id)
         OR (follower_id = NEW.blocked_id AND followee_id = NEW.blocker_id));
END;


CREATE TRIGGER trg_follow_blocked
BEFORE INSERT ON follow
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'cannot follow across an active block')
    WHERE EXISTS (SELECT 1 FROM block
                  WHERE ended_at IS NULL
                    AND ((blocker_id = NEW.follower_id AND blocked_id = NEW.followee_id)
                      OR (blocker_id = NEW.followee_id AND blocked_id = NEW.follower_id)));
END;


CREATE TRIGGER trg_moderation_no_update BEFORE UPDATE ON moderation_decision
BEGIN SELECT RAISE(ABORT, 'moderation_decision is append-only'); END;

CREATE TRIGGER trg_moderation_no_delete BEFORE DELETE ON moderation_decision
BEGIN SELECT RAISE(ABORT, 'moderation_decision is append-only'); END;

CREATE TRIGGER trg_impression_no_update BEFORE UPDATE ON impression
BEGIN SELECT RAISE(ABORT, 'impression is append-only'); END;

CREATE TRIGGER trg_signal_immutable
BEFORE UPDATE ON engagement_signal
FOR EACH ROW
WHEN NOT (OLD.kind = 'like' AND OLD.ended_at IS NULL AND NEW.ended_at IS NOT NULL
          AND NEW.signal_id = OLD.signal_id AND NEW.impression_id = OLD.impression_id
          AND NEW.kind = OLD.kind AND NEW.occurred_at = OLD.occurred_at)
BEGIN
    SELECT RAISE(ABORT, 'engagement_signal rows may only be closed (like -> ended_at), never edited');
END;


CREATE TRIGGER trg_unlike_targets_like
BEFORE INSERT ON engagement_signal
FOR EACH ROW
WHEN NEW.kind = 'unlike'
BEGIN
    SELECT RAISE(ABORT, 'unlike must reference an open like on the same impression')
    WHERE NOT EXISTS (SELECT 1 FROM engagement_signal l
                      WHERE l.signal_id = NEW.retracts_signal_id
                        AND l.kind = 'like'
                        AND l.impression_id = NEW.impression_id
                        AND l.occurred_at <= NEW.occurred_at);
END;


CREATE TABLE moderation_audit (
    audit_id       INTEGER PRIMARY KEY,
    decision_id    INTEGER NOT NULL REFERENCES moderation_decision(decision_id) ON DELETE RESTRICT,
    video_id       INTEGER NOT NULL,
    previous_state TEXT,           
    new_state      TEXT NOT NULL,
    decided_by_kind TEXT NOT NULL,
    logged_at      TEXT NOT NULL
);

CREATE TRIGGER trg_moderation_audit
AFTER INSERT ON moderation_decision
FOR EACH ROW
BEGIN
    INSERT INTO moderation_audit (decision_id, video_id, previous_state, new_state, decided_by_kind, logged_at)
    SELECT NEW.decision_id, NEW.video_id,
           (SELECT new_state FROM moderation_decision
             WHERE video_id = NEW.video_id AND decision_id <> NEW.decision_id
             ORDER BY decided_at DESC, decision_id DESC LIMIT 1),
           NEW.new_state, NEW.decided_by_kind,
           strftime('%Y-%m-%dT%H:%M:%SZ', 'now');
END;


CREATE TRIGGER trg_tier_no_overlap_ins
BEFORE INSERT ON creator_tier_period
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'creator_tier_period: overlapping interval')
    WHERE EXISTS (SELECT 1 FROM creator_tier_period p
                  WHERE p.creator_id = NEW.creator_id
                    AND p.valid_from < coalesce(NEW.valid_to, '9999-12-31T23:59:59Z')
                    AND coalesce(p.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from);
END;

CREATE TRIGGER trg_tier_no_overlap_upd
BEFORE UPDATE OF valid_from, valid_to ON creator_tier_period
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'creator_tier_period: overlapping interval')
    WHERE EXISTS (SELECT 1 FROM creator_tier_period p
                  WHERE p.creator_id = NEW.creator_id
                    AND NOT (p.creator_id = OLD.creator_id AND p.valid_from = OLD.valid_from)
                    AND p.valid_from < coalesce(NEW.valid_to, '9999-12-31T23:59:59Z')
                    AND coalesce(p.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from);
END;

CREATE TRIGGER trg_price_no_overlap_ins
BEFORE INSERT ON model_price
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'model_price: overlapping interval')
    WHERE EXISTS (SELECT 1 FROM model_price p
                  WHERE p.model_id = NEW.model_id
                    AND p.valid_from < coalesce(NEW.valid_to, '9999-12-31T23:59:59Z')
                    AND coalesce(p.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from);
END;

CREATE TRIGGER trg_price_no_overlap_upd
BEFORE UPDATE OF valid_from, valid_to ON model_price
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'model_price: overlapping interval')
    WHERE EXISTS (SELECT 1 FROM model_price p
                  WHERE p.model_id = NEW.model_id
                    AND NOT (p.model_id = OLD.model_id AND p.valid_from = OLD.valid_from)
                    AND p.valid_from < coalesce(NEW.valid_to, '9999-12-31T23:59:59Z')
                    AND coalesce(p.valid_to, '9999-12-31T23:59:59Z') > NEW.valid_from);
END;

-- 8.3 Deletion grace period. A suspended account (pending_deletion or
-- deleted) must not be visible. The visibility rule lives in the view
-- layer (views.sql); this trigger closes the remaining write-side gap by
-- refusing new social edges and sessions from or to a suspended account.
CREATE TRIGGER trg_no_follow_suspended
BEFORE INSERT ON follow
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'suspended accounts cannot take part in follows')
    WHERE EXISTS (SELECT 1 FROM app_user
                  WHERE user_id IN (NEW.follower_id, NEW.followee_id)
                    AND account_state IN ('pending_deletion', 'deleted'));
END;

CREATE TRIGGER trg_no_session_suspended
BEFORE INSERT ON agent_session
FOR EACH ROW
BEGIN
    SELECT RAISE(ABORT, 'suspended accounts cannot start agent sessions')
    WHERE EXISTS (SELECT 1 FROM app_user
                  WHERE user_id = NEW.user_id
                    AND account_state IN ('pending_deletion', 'deleted'));
END;

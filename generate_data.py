"""
ScrollSense synthetic data generator.

Loads a freshly created scrollsense.db (see README.md for the order of
operations) with volumes controlled by the parameter block below. Every
random choice flows from SEED, so the same seed always yields the same
database. The whole load is a single transaction.
"""

import json
import math
import random
import sqlite3
import sys
import time
from datetime import datetime, timedelta, timezone

# ---- parameters (later assignments will change only this block) ----
SEED             = "GE26Z835"      # roll number
N_USERS          = 5_000
N_VIDEOS         = 20_000
N_IMPRESSIONS    = 300_000
N_AGENT_SESSIONS = 2_000
SCALE            = 1               # multiplies the four volumes above
DB_PATH          = "scrollsense.db"
# --------------------------------------------------------------------

N_USERS          *= SCALE
N_VIDEOS         *= SCALE
N_IMPRESSIONS    *= SCALE
N_AGENT_SESSIONS *= SCALE

rng = random.Random(SEED)

# Observation window for telemetry and agent traffic.
WINDOW_START = datetime(2026, 6, 1, tzinfo=timezone.utc)
WINDOW_END   = datetime(2026, 9, 8, 23, 59, 59, tzinfo=timezone.utc)
CONTENT_START = datetime(2026, 2, 1, tzinfo=timezone.utc)
ACCOUNT_START = datetime(2024, 9, 1, tzinfo=timezone.utc)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def rand_between(a, b):
    """Uniform instant between two datetimes."""
    span = (b - a).total_seconds()
    return a + timedelta(seconds=rng.random() * span)


# Hour-of-day weights: a student audience, quiet at night, peaking 20:00-23:00.
HOUR_WEIGHTS = [1, 0.6, 0.3, 0.2, 0.2, 0.3, 0.8, 1.5, 2.2, 2.5, 2.6, 2.8,
                3.2, 3.0, 2.8, 2.9, 3.1, 3.4, 3.8, 4.4, 5.0, 5.4, 4.6, 2.6]
DOW_WEIGHTS = [1.0, 0.95, 0.95, 1.0, 1.15, 1.35, 1.3]   # Mon..Sun


_DAYS = [WINDOW_START + timedelta(days=i) for i in range((WINDOW_END - WINDOW_START).days + 1)]
_DAY_W = [DOW_WEIGHTS[d.weekday()] for d in _DAYS]
_HOURS = list(range(24))


def rhythm_instant(a, b):
    """An instant inside [a, b] that follows the daily and weekly rhythm."""
    for _ in range(30):
        day = rng.choices(_DAYS, weights=_DAY_W)[0]
        hour = rng.choices(_HOURS, weights=HOUR_WEIGHTS)[0]
        dt = day.replace(hour=hour, minute=rng.randrange(60), second=rng.randrange(60))
        if a <= dt <= b:
            return dt
    return rand_between(a, b)


def zipf_weights(n, s=1.05):
    return [1.0 / (k ** s) for k in range(1, n + 1)]


def lognormal_ms(median_ms, sigma):
    return int(rng.lognormvariate(math.log(median_ms), sigma))


# ---------------------------------------------------------------------
# Vocabulary
# ---------------------------------------------------------------------
FIRST = ["aarav", "maya", "kiran", "sita", "ravi", "nisha", "dev", "anya", "rohan",
         "leela", "arjun", "priya", "sam", "tara", "vik", "zoe", "ishan", "meera",
         "kabir", "asha", "noor", "omar", "lina", "yash", "rhea", "tenzin", "pema",
         "bikash", "sunita", "hari", "anil", "gita", "raj", "mina", "suman"]
SUFFIX = ["", "_", ".", "x", "01", "22", "99", "7", "_official", "vlogs", "clips"]

CATEGORIES = ["comedy", "cats", "dogs", "football", "cricket", "cooking", "study",
              "music", "dance", "gaming", "travel", "fashion", "tech", "art", "fitness",
              "memes", "anime", "science", "books", "nature"]

WORDS = ["when", "the", "cat", "thinks", "it", "is", "a", "dog", "pov", "you", "finally",
         "finish", "exam", "week", "late", "night", "study", "session", "this", "sound",
         "lives", "in", "my", "head", "rent", "free", "day", "life", "campus", "try",
         "not", "to", "laugh", "wait", "for", "end", "part", "two", "tutorial", "vibes",
         "morning", "coffee", "rain", "walk", "dorm", "roommate", "prank", "recipe"]

TAG_VOCAB = ["fyp", "foryou", "viral", "comedy", "cat", "catsofscrollsense", "dog",
             "study", "studytok", "college", "campuslife", "exam", "funny", "memes",
             "football", "cricket", "cooking", "recipe", "music", "dance", "trending",
             "art", "gaming", "travel", "nepal", "india", "fashion", "ootd", "fitness",
             "gym", "anime", "science", "books", "nature", "sunset", "roommate", "prank",
             "tutorial", "lifehack", "pov", "duet", "sound", "vlog", "dayinmylife",
             "aesthetic", "chill", "rain", "coffee", "night", "morning"]
TAG_VOCAB += [f"tag{i}" for i in range(len(TAG_VOCAB), 400)]

TRACK_TITLES = ["Sunset Loop", "Dorm Beat", "Cat Walk", "Exam Season", "Late Night Lofi",
                "Campus Anthem", "Rainy Day", "Coffee Break", "Monsoon", "Chai Time",
                "Bass Drop", "Whistle", "Marching", "Glow", "Echo", "Drift", "Pulse",
                "Bloom", "Static", "Neon"]

USER_MESSAGES_SEARCH = [
    "find me that clip about the cat that thinks it's a dog",
    "show me study clips with lofi music",
    "anything funny about roommates",
    "clips using the sunset loop sound",
    "cricket highlights from this week",
    "best cooking clips under a minute",
    "what is trending in nepal right now",
    "find the exam week pov clip",
]
USER_MESSAGES_WHY = [
    "Why this?", "why am I seeing this", "why was this recommended",
    "explain this recommendation",
]
FOLLOWUPS = ["show me more like that", "no, the other one", "only ones with music",
             "from creators I follow", "something shorter", "thanks, one more"]


def random_case(word):
    r = rng.random()
    if r < 0.55:
        return word
    if r < 0.8:
        return word.capitalize()
    if r < 0.9:
        return word.upper()
    return "".join(ch.upper() if rng.random() < 0.5 else ch for ch in word)


# ---------------------------------------------------------------------
# Generation
# ---------------------------------------------------------------------
def main():
    t0 = time.time()
    con = sqlite3.connect(DB_PATH)
    con.execute("PRAGMA foreign_keys = ON")
    ver = con.execute("SELECT sqlite_version()").fetchone()[0]
    if tuple(int(p) for p in ver.split(".")) < (3, 44, 0):
        sys.exit(f"SQLite {ver} is too old; 3.44 or later is required")
    if con.execute("SELECT count(*) FROM app_user").fetchone()[0]:
        sys.exit("scrollsense.db already contains data; start from an empty file")

    cur = con.cursor()
    cur.execute("BEGIN")

    # ---- interest categories --------------------------------------
    cur.executemany("INSERT INTO interest_category(category_id, name) VALUES (?, ?)",
                    [(i + 1, c) for i, c in enumerate(CATEGORIES)])

    # ---- users ------------------------------------------------------
    handles = set()
    users = []           # (user_id, handle, display_name, state, deletion_requested_at, created_at)
    user_created = {}
    for uid in range(1, N_USERS + 1):
        while True:
            h = rng.choice(FIRST) + rng.choice(SUFFIX) + (str(rng.randrange(1000)) if rng.random() < 0.6 else "")
            if 3 <= len(h) <= 30 and h.lower() not in handles:
                handles.add(h.lower())
                break
        created = rand_between(ACCOUNT_START, WINDOW_END - timedelta(days=1))
        r = rng.random()
        if r < 0.965:
            state, del_at = "active", None
        elif r < 0.985:
            state, del_at = "deactivated", None
        elif r < 0.995:
            state = "pending_deletion"
            del_at = iso(rand_between(WINDOW_END - timedelta(days=29), WINDOW_END))
        else:
            state = "deleted"
            del_at = iso(rand_between(created + timedelta(days=1), WINDOW_END - timedelta(days=31)))
        users.append((uid, random_case(h) if rng.random() < 0.3 else h, h.replace("_", " ").title(),
                      state, del_at, iso(created)))
        user_created[uid] = created
    cur.executemany("INSERT INTO app_user(user_id, handle, display_name, account_state, deletion_requested_at, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?)", users)
    user_state = {u[0]: u[3] for u in users}
    usable_users = [u[0] for u in users if u[3] in ("active", "deactivated")]
    active_users = [u[0] for u in users if u[3] == "active"]

    # ---- auth identities -------------------------------------------
    idents = []
    for uid, _, _, state, _, created in users:
        if state == "deleted":
            continue          # PII purged after the window
        r = rng.random()
        provs = ["phone"] if r < 0.6 else (["google"] if r < 0.9 else ["phone", "google"])
        for p in provs:
            subj = f"+977{rng.randrange(9700000000, 9899999999)}" if p == "phone" else f"{uid}.{rng.randrange(10**9, 10**10)}@gmail.com"
            idents.append((uid, p, subj, created))
    cur.executemany("INSERT INTO auth_identity(user_id, provider, provider_subject, verified_at) VALUES (?, ?, ?, ?)", idents)

    # ---- handle change history -------------------------------------
    changes = []
    for uid in rng.sample(usable_users, N_USERS // 20):
        n = 1 if rng.random() < 0.8 else 2
        base = user_created[uid]
        for _ in range(n):
            when = rand_between(base, WINDOW_END)
            old = f"old{uid}_{rng.randrange(100)}"
            changes.append((uid, old, users[uid - 1][1], iso(when)))
    cur.executemany("INSERT INTO handle_change(user_id, old_handle, new_handle, changed_at) VALUES (?, ?, ?, ?)", changes)

    # ---- declared and inferred interests -----------------------------
    declared = []
    for uid in usable_users:
        for cid in rng.sample(range(1, len(CATEGORIES) + 1), rng.choice([1, 2, 2, 3, 3, 4])):
            declared.append((uid, cid, users[uid - 1][5]))
    cur.executemany("INSERT INTO user_declared_interest VALUES (?, ?, ?)", declared)

    refresh_dates = []
    d = WINDOW_START
    while d <= WINDOW_END:
        refresh_dates.append(d.replace(hour=3))
        d += timedelta(days=7)
    inferred = []
    suppress = []
    for uid in usable_users:
        cats = rng.sample(range(1, len(CATEGORIES) + 1), 3)
        base = {c: rng.random() for c in cats}
        for rd in refresh_dates:
            for c in cats:
                base[c] = min(1.0, max(0.0, base[c] + rng.gauss(0, 0.05)))
                inferred.append((uid, c, iso(rd), round(base[c], 3)))
        if rng.random() < 0.08:
            c = rng.choice(cats)
            s_at = rand_between(WINDOW_START, WINDOW_END)
            lifted = iso(rand_between(s_at + timedelta(days=1), WINDOW_END)) if rng.random() < 0.2 and s_at < WINDOW_END - timedelta(days=2) else None
            suppress.append((uid, c, iso(s_at), lifted))
    cur.executemany("INSERT INTO inferred_interest_score VALUES (?, ?, ?, ?)", inferred)
    cur.executemany("INSERT INTO inferred_interest_suppression VALUES (?, ?, ?, ?)", suppress)

    # ---- creators and tier history ---------------------------------
    n_creators = max(50, N_USERS // 8)
    creators = rng.sample(usable_users, n_creators)
    cur.executemany("INSERT INTO creator(creator_id, became_creator_at) VALUES (?, ?)",
                    [(c, iso(max(user_created[c], CONTENT_START - timedelta(days=30)))) for c in creators])

    tiers = ["none", "bronze", "silver", "gold", "partner"]
    tier_rows = []
    for c in creators:
        start = max(user_created[c], CONTENT_START - timedelta(days=30))
        n_periods = rng.choices([1, 2, 3], weights=[50, 35, 15])[0]
        level = 0
        cuts = sorted(rand_between(start + timedelta(days=1), WINDOW_END - timedelta(days=1)) for _ in range(n_periods - 1))
        bounds = [start] + cuts + [None]
        for i in range(n_periods):
            vf, vt = bounds[i], bounds[i + 1]
            tier_rows.append((c, tiers[level], iso(vf), iso(vt) if vt else None))
            level = min(4, level + rng.choice([1, 1, 2]))
    cur.executemany("INSERT INTO creator_tier_period VALUES (?, ?, ?, ?)", tier_rows)

    # ---- videos, audio tracks, hashtags ------------------------------
    # videos per creator: roughly power-law
    cw = zipf_weights(n_creators, 0.9)
    owners = rng.choices(creators, weights=cw, k=N_VIDEOS)

    n_tracks = max(200, N_VIDEOS // 7)
    n_licensed = n_tracks // 3
    tracks = []      # (track_id, title, kind, origin_video_id, licence_ref, created_at)
    for tid in range(1, n_licensed + 1):
        tracks.append((tid, f"{rng.choice(TRACK_TITLES)} {tid}", "licensed", None,
                       f"CAT-{rng.randrange(10000, 99999)}", iso(rand_between(CONTENT_START - timedelta(days=200), CONTENT_START))))
    # original tracks are created together with their origin video below
    track_pop = zipf_weights(n_tracks, 1.1)

    videos = []
    video_tags = []
    tag_ids = {}
    upload_time = {}
    duration = {}
    original_pending = list(range(n_licensed + 1, n_tracks + 1))
    tag_weights = zipf_weights(len(TAG_VOCAB), 1.0)
    for vid in range(1, N_VIDEOS + 1):
        up = rand_between(CONTENT_START, WINDOW_END)
        upload_time[vid] = up
        dur = min(90000, max(20000, lognormal_ms(34000, 0.35)))
        duration[vid] = dur
        # caption with hashtags in inconsistent case
        n_words = rng.randrange(3, 12)
        cap = " ".join(rng.choice(WORDS) for _ in range(n_words))
        tags = []
        if rng.random() < 0.85:
            k = rng.choices([1, 2, 3, 4, 5], weights=[30, 30, 20, 12, 8])[0]
            chosen = []
            for t in rng.choices(TAG_VOCAB, weights=tag_weights, k=k):
                if t not in chosen:
                    chosen.append(t)
            tags = chosen
            sep = rng.choice([" ", "  ", " ,", "."])
            cap = cap + sep + " ".join("#" + random_case(t) + rng.choice(["", "", ",", "!"]) for t in tags)
        # audio
        track_id = None
        if original_pending and rng.random() < 0.04:
            tid = original_pending.pop()
            tracks.append((tid, f"original sound - {users[owners[vid - 1] - 1][1]}", "original", vid, None, iso(up)))
            track_id = tid
        elif rng.random() < 0.62:
            track_id = rng.choices(range(1, n_tracks + 1), weights=track_pop)[0]
        videos.append((vid, owners[vid - 1], dur, cap, track_id, iso(up)))
        for pos, t in enumerate(tags, start=1):
            if t not in tag_ids:
                tag_ids[t] = len(tag_ids) + 1
            video_tags.append((vid, tag_ids[t], pos))
    # any original track never assigned gets attached to a random video that has no track
    for tid in original_pending:
        vid = rng.randrange(1, N_VIDEOS + 1)
        tracks.append((tid, f"original sound {tid}", "original", vid, None, iso(upload_time[vid])))
    tracks.sort()
    # only videos whose track exists: original tracks reference videos, keep as is
    cur.executemany("INSERT INTO audio_track(track_id, title, kind, origin_video_id, licence_catalogue_ref, created_at) VALUES (?, ?, ?, ?, ?, ?)", tracks)
    cur.executemany("INSERT INTO video(video_id, owner_creator_id, duration_ms, caption, audio_track_id, uploaded_at) VALUES (?, ?, ?, ?, ?, ?)", videos)
    cur.executemany("INSERT INTO hashtag(hashtag_id, tag) VALUES (?, ?)", [(i, t) for t, i in tag_ids.items()])
    cur.executemany("INSERT INTO video_hashtag(video_id, hashtag_id, position) VALUES (?, ?, ?)", video_tags)
    video_owner = {v[0]: v[1] for v in videos}

    # ---- moderation history ------------------------------------------
    reviewers = rng.sample(active_users, 25)
    mod_rows = []
    for vid in range(1, N_VIDEOS + 1):
        t = upload_time[vid]
        seq = [("pending", "classifier")]
        r = rng.random()
        if r < 0.90:
            seq.append(("live", "classifier"))
        elif r < 0.95:
            seq.append(("age_restricted", "classifier"))
        elif r < 0.98:
            seq += [("live", "classifier"), ("demoted", "human")]
        else:
            seq += [("live", "classifier"), ("demoted", "human"), ("taken_down", "human")]
        if rng.random() < 0.03 and seq[-1][0] != "taken_down":
            seq += [("demoted", "classifier"), ("live", "human")]
        used = set()
        deduped = []
        for state, who in seq:            # a decision that repeats the current state is not a decision
            if not deduped or deduped[-1][0] != state:
                deduped.append((state, who))
        for state, who in deduped:
            t = t + timedelta(seconds=rng.randrange(5, 3 * 86400))
            if t > WINDOW_END:
                break
            key = iso(t)
            if key in used:
                continue
            used.add(key)
            mod_rows.append((vid, state, key, who,
                             f"clf-v{rng.choice([12, 13, 14])}" if who == "classifier" else None,
                             rng.choice(reviewers) if who == "human" else None,
                             rng.choice(["policy 4.2", "community report", "appeal upheld", None]) if who == "human" else None))
    cur.executemany("INSERT INTO moderation_decision(video_id, new_state, decided_at, decided_by_kind, classifier_version, reviewer_user_id, reason) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)", mod_rows)

    # ---- social graph ------------------------------------------------
    follow_rows = []
    follow_set = set()
    follow_start = {}
    creator_w = zipf_weights(n_creators, 1.0)
    n_follows = N_USERS * 9
    for _ in range(n_follows):
        a = rng.choice(active_users)
        b = rng.choices(creators, weights=creator_w)[0] if rng.random() < 0.85 else rng.choice(active_users)
        if a == b or (a, b) in follow_set:
            continue
        follow_set.add((a, b))
        st = rand_between(max(user_created[a], user_created[b]), WINDOW_END)
        ended, reason = None, None
        if rng.random() < 0.06 and st < WINDOW_END - timedelta(days=1):
            ended, reason = iso(rand_between(st, WINDOW_END)), "unfollow"
        follow_rows.append((a, b, iso(st), ended, reason))
        follow_start[(a, b)] = st
    cur.executemany("INSERT INTO follow VALUES (?, ?, ?, ?, ?)", follow_rows)

    blocks = []
    seen = set()
    for _ in range(N_USERS // 10):
        a, b = rng.sample(active_users, 2)
        if (a, b) in seen:
            continue
        seen.add((a, b))
        # a block can only be placed after any follow between the pair began
        lo = max(WINDOW_START, follow_start.get((a, b), WINDOW_START), follow_start.get((b, a), WINDOW_START))
        if lo >= WINDOW_END:
            continue
        st = rand_between(lo, WINDOW_END)
        blocks.append((a, b, iso(st), None))
    cur.executemany("INSERT INTO block VALUES (?, ?, ?, ?)", blocks)   # trigger ends open follows
    blocked_pairs = {(a, b) for a, b, _, _ in blocks} | {(b, a) for a, b, _, _ in blocks}

    mutes = []
    seen = set()
    for _ in range(N_USERS * 3 // 10):
        a, b = rng.sample(active_users, 2)
        if (a, b) in seen:
            continue
        seen.add((a, b))
        st = rand_between(WINDOW_START, WINDOW_END)
        mutes.append((a, b, iso(st), None))
    cur.executemany("INSERT INTO mute VALUES (?, ?, ?, ?)", mutes)

    # ---- LLM models, prices, templates ---------------------------------
    models = [(1, "gpt-4o-mini", "openai", 0), (2, "llama-3.1-70b", "meta-hosted", 0),
              (3, "ss-explainer-ft-2", "scrollsense", 1), (4, "gpt-4o", "openai", 0)]
    cur.executemany("INSERT INTO llm_model VALUES (?, ?, ?, ?)", models)
    prices = [
        # model, valid_from, valid_to, input, output, cached (USD per million tokens)
        (1, "2026-01-01T00:00:00Z", "2026-07-15T00:00:00Z", 0.150, 0.600, 0.075),
        (1, "2026-07-15T00:00:00Z", None,                   0.120, 0.480, 0.060),
        (2, "2026-01-01T00:00:00Z", "2026-08-01T00:00:00Z", 0.900, 0.900, 0.450),
        (2, "2026-08-01T00:00:00Z", None,                   0.700, 0.700, 0.350),
        (3, "2026-01-01T00:00:00Z", None,                   0.300, 0.300, 0.100),
        (4, "2026-01-01T00:00:00Z", "2026-06-20T00:00:00Z", 2.500, 10.000, 1.250),
        (4, "2026-06-20T00:00:00Z", None,                   2.000, 8.000, 1.000),
    ]
    cur.executemany("INSERT INTO model_price VALUES (?, ?, ?, ?, ?, ?)", prices)

    cur.executemany("INSERT INTO prompt_template VALUES (?, ?, ?)",
                    [(1, "explainer", "explainer"), (2, "conversational_search", "search")])
    tv_rows = []
    tv_by_template = {1: [], 2: []}
    tvid = 0
    for tmpl, n_ver in ((1, 22), (2, 15)):
        t = CONTENT_START
        for v in range(1, n_ver + 1):
            tvid += 1
            t = t + timedelta(days=rng.uniform(3, 12))
            body = (f"You are the ScrollSense {'explainer' if tmpl == 1 else 'search assistant'}. Version {v}. "
                    + " ".join(rng.choice(WORDS) for _ in range(30)))
            tv_rows.append((tvid, tmpl, v, body, iso(t)))
            tv_by_template[tmpl].append((t, tvid))
    cur.executemany("INSERT INTO prompt_template_version VALUES (?, ?, ?, ?, ?)", tv_rows)

    def template_version_at(tmpl, when):
        chosen = tv_by_template[tmpl][0][1]
        for t, i in tv_by_template[tmpl]:
            if t <= when:
                chosen = i
        return chosen

    rankers = [(1, "ranker-v7", "2026-01-10T00:00:00Z"), (2, "ranker-v8", "2026-06-25T00:00:00Z"),
               (3, "ranker-v9", "2026-08-12T00:00:00Z")]
    cur.executemany("INSERT INTO ranker_version VALUES (?, ?, ?)", rankers)

    def ranker_at(when):
        s = iso(when)
        return max(r[0] for r in rankers if r[2] <= s)

    # ---- feed impressions ---------------------------------------------
    # Reserve a slice of the impression budget for clips shown from agent shelves.
    n_shelf_budget = N_AGENT_SESSIONS * 2
    n_feed = N_IMPRESSIONS - n_shelf_budget
    viewer_w = zipf_weights(len(usable_users), 0.75)
    rng.shuffle(usable_users)
    video_pop = zipf_weights(N_VIDEOS, 0.8)
    video_ids = list(range(1, N_VIDEOS + 1))
    rng.shuffle(video_ids)

    impressions = []       # [user_id, video_id, shown_at(dt), feed_position, ranker, recommendation_id]
    imp_keys = set()

    def feed_impressions(target, out):
        """Append feed impressions to out until it holds target rows."""
        while len(out) < target:
            need = target - len(out)
            picked_users = rng.choices(usable_users, weights=viewer_w, k=need)
            picked_videos = rng.choices(video_ids, weights=video_pop, k=need)
            for u, v in zip(picked_users, picked_videos):
                lo = max(WINDOW_START, upload_time[v], user_created[u])
                if lo >= WINDOW_END:
                    continue
                when = rhythm_instant(lo, WINDOW_END)
                key = (u, v, iso(when))
                if key in imp_keys:
                    continue
                imp_keys.add(key)
                pos = min(80, 1 + int(rng.expovariate(1 / 12.0)))
                out.append([u, v, when, pos, ranker_at(when), None])

    feed_impressions(n_feed, impressions)
    impressions.sort(key=lambda r: r[2])

    # ---- agent sessions -------------------------------------------------
    session_rows, turn_rows, am_rows, tool_rows, rec_rows, judge_rows, rating_rows = [], [], [], [], [], [], []
    shelf_impressions = []
    turn_id = 0
    call_id = 0
    rec_id = 0
    user_impr_index = {}
    for idx, imp in enumerate(impressions):
        user_impr_index.setdefault(imp[0], []).append(idx)

    for sid in range(1, N_AGENT_SESSIONS + 1):
        why = rng.random() < 0.4
        if why:
            u = rng.choice(active_users)
            if u not in user_impr_index:
                why = False
        if why:
            imp_idx = rng.choice(user_impr_index[u])
            start = impressions[imp_idx][2] + timedelta(seconds=rng.randrange(2, 90))
            trigger = imp_idx + 1     # impression_id is assigned in list order below
        else:
            u = rng.choice(active_users)
            start = rhythm_instant(max(WINDOW_START, user_created[u]), WINDOW_END)
            trigger = None
        n_turns = rng.choices([1, 2, 3, 4], weights=[45, 30, 15, 10])[0]
        t = start
        for ti in range(1, n_turns + 1):
            turn_id += 1
            msg = rng.choice(USER_MESSAGES_WHY if why else USER_MESSAGES_SEARCH) if ti == 1 else rng.choice(FOLLOWUPS)
            turn_rows.append((turn_id, sid, ti, msg, iso(t)))
            if rng.random() < 0.97:     # a few turns never received an answer
                model = rng.choices([1, 2, 3], weights=[45, 25, 30])[0] if not why else rng.choices([3, 1], weights=[70, 30])[0]
                tmpl = 1 if why else 2
                # tool calls
                depth_calls = []

                def make_call(parent, depth, index, when):
                    nonlocal call_id
                    call_id += 1
                    if depth == 0:
                        name = "get_user_history" if why and rng.random() < 0.6 else rng.choice(["search_videos", "fetch_trending_audio", "get_user_history"])
                    else:
                        name = rng.choice(["rerank", "lookup_creator", "search_videos", "fetch_trending_audio"])
                    args = {
                        "search_videos": {"query": rng.choice(USER_MESSAGES_SEARCH), "filters": {"max_duration_s": rng.choice([30, 60, 90]), "live_only": True}},
                        "get_user_history": {"days": rng.choice([7, 14, 30])},
                        "fetch_trending_audio": {"region": rng.choice(["NP", "IN", "GLOBAL"])},
                        "rerank": {"candidates": rng.randrange(5, 40), "strategy": rng.choice(["recency", "affinity"])},
                        "lookup_creator": {"creator_id": rng.choice(creators)},
                    }[name]
                    errored = 1 if rng.random() < 0.04 else 0
                    lat = lognormal_ms(120 if depth else 260, 0.6)
                    cid = call_id
                    tool_rows.append((cid, turn_id, parent, index, name, json.dumps(args),
                                      None if errored else f"{rng.randrange(0, 40)} results",
                                      lat, errored, "upstream timeout" if errored else None, iso(when)))
                    if depth < 5 and rng.random() < (0.45 if depth == 0 else 0.3):
                        for j in range(1, rng.choice([1, 1, 2, 3]) + 1):
                            make_call(cid, depth + 1, j, when + timedelta(milliseconds=j * 40))
                    return cid

                n_top = rng.choices([0, 1, 2, 3], weights=[10, 45, 30, 15])[0] if not why else rng.choices([0, 1, 2], weights=[20, 60, 20])[0]
                for j in range(1, n_top + 1):
                    make_call(None, 0, j, t + timedelta(milliseconds=200 * j))

                in_tok = int(lognormal_ms(1400, 0.4))
                out_tok = int(lognormal_ms(160, 0.5))
                cached = int(in_tok * rng.choice([0, 0, 0.3, 0.5, 0.7]))
                latency = int(lognormal_ms(1800, 0.5))
                resp = t + timedelta(milliseconds=latency)
                am_rows.append((turn_id, template_version_at(tmpl, resp), model,
                                rng.choice([0.2, 0.3, 0.5, 0.7]),
                                "Here is what I found." if not why else "This clip was surfaced because it matches your interests.",
                                in_tok, out_tok, cached, latency, iso(resp)))
                # shelf of recommendations for search sessions
                if not why and rng.random() < 0.85:
                    shelf = rng.sample(video_ids, rng.choice([3, 4, 5, 6, 8]))
                    for pos, v in enumerate(shelf, start=1):
                        rec_id += 1
                        rec_rows.append((rec_id, turn_id, pos, v))
                        # did the user open it?
                        if rng.random() < 0.42 and len(shelf_impressions) < n_shelf_budget:
                            when = resp + timedelta(seconds=rng.randrange(3, 600) + pos * 4)
                            if when <= WINDOW_END and upload_time[v] <= when:
                                key = (u, v, iso(when))
                                if key not in imp_keys:
                                    imp_keys.add(key)
                                    shelf_impressions.append([u, v, when, pos, ranker_at(when), rec_id])
                                    if rng.random() < 0.06 and len(shelf_impressions) < n_shelf_budget:
                                        when2 = when + timedelta(seconds=rng.randrange(60, 3600))
                                        key2 = (u, v, iso(when2))
                                        if when2 <= WINDOW_END and key2 not in imp_keys:
                                            imp_keys.add(key2)
                                            shelf_impressions.append([u, v, when2, pos, ranker_at(when2), rec_id])
                # judge and user rating
                if rng.random() < 0.28:
                    base = rng.uniform(2.0, 5.0)
                    judge_rows.append((turn_id, 4, round(min(5, max(0, base + rng.gauss(0, 0.3))), 2),
                                       round(min(5, max(0, base + rng.gauss(0, 0.4))), 2),
                                       round(min(5, max(0, 4.4 + rng.gauss(0, 0.4))), 2),
                                       iso(resp + timedelta(minutes=rng.randrange(5, 600)))))
                if rng.random() < 0.05:
                    rating_rows.append((turn_id, 1 if rng.random() < 0.62 else -1, iso(resp + timedelta(seconds=rng.randrange(2, 120)))))
                t = resp + timedelta(seconds=rng.randrange(5, 240))
            else:
                t = t + timedelta(seconds=rng.randrange(30, 300))
        session_rows.append((sid, u, "why_this" if why else "search", trigger, iso(start),
                             iso(t) if rng.random() < 0.9 else None))

    cur.executemany("INSERT INTO agent_session VALUES (?, ?, ?, ?, ?, ?)", session_rows)
    cur.executemany("INSERT INTO agent_turn VALUES (?, ?, ?, ?, ?)", turn_rows)
    cur.executemany("INSERT INTO assistant_message VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", am_rows)
    cur.executemany("INSERT INTO tool_call VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", tool_rows)
    cur.executemany("INSERT INTO recommendation VALUES (?, ?, ?, ?)", rec_rows)
    cur.executemany("INSERT INTO judge_score VALUES (?, ?, ?, ?, ?, ?)", judge_rows)
    cur.executemany("INSERT INTO user_rating VALUES (?, ?, ?)", rating_rows)

    # ---- all impressions, view segments, signals -------------------------
    # Feed rows go first so the why_this trigger ids assigned above stay valid;
    # the budget not used by shelf clips is topped up with ordinary feed rows.
    topup = []
    feed_impressions(N_IMPRESSIONS - len(impressions) - len(shelf_impressions), topup)
    all_imps = impressions + shelf_impressions + topup
    imp_rows = [(i + 1, r[0], r[1], iso(r[2]), r[3], r[4], r[5]) for i, r in enumerate(all_imps)]
    cur.executemany("INSERT INTO impression VALUES (?, ?, ?, ?, ?, ?, ?)", imp_rows)

    seg_rows, sig_rows, comment_rows, follow_from_feed = [], [], [], []
    signal_id = 0
    for i, r in enumerate(all_imps):
        imp_id = i + 1
        u, v, when = r[0], r[1], r[2]
        dur = duration[v]
        p_view = 0.30 if r[5] is None else 0.65     # shelf clips were asked for
        if rng.random() >= p_view:
            continue
        n_seg = rng.choices([1, 2, 3, 4], weights=[74, 18, 6, 2])[0]
        t = when + timedelta(milliseconds=rng.randrange(300, 1500))
        completed = False
        for s in range(1, n_seg + 1):
            watched = max(300, min(int(dur * 2.5), lognormal_ms(int(dur * 0.35), 0.9)))
            reached = 1 if watched >= dur else 0
            completed = completed or bool(reached)
            seg_rows.append((imp_id, s, iso(t), watched, reached))
            t = t + timedelta(milliseconds=watched + rng.randrange(500, 20000))
        # explicit signals, mostly absent
        base_time = t
        r2 = rng.random()
        if r2 < 0.09:
            signal_id += 1
            like_at = base_time + timedelta(seconds=rng.randrange(0, 30))
            like_id = signal_id
            ended = None
            retract_at = None
            if rng.random() < 0.12:
                delay = rng.randrange(3, 60) if rng.random() < 0.35 else rng.randrange(61, 86400 * 3)
                retract_at = like_at + timedelta(seconds=delay)
                if retract_at > WINDOW_END:
                    retract_at = None
                ended = iso(retract_at) if retract_at else None
            sig_rows.append((like_id, imp_id, "like", iso(like_at), None, None, ended, None))
            if retract_at:
                signal_id += 1
                sig_rows.append((signal_id, imp_id, "unlike", iso(retract_at), None, like_id, None, None))
        elif r2 < 0.11:
            signal_id += 1
            sig_rows.append((signal_id, imp_id, "save", iso(base_time), None, None, None, None))
        elif r2 < 0.125:
            signal_id += 1
            sig_rows.append((signal_id, imp_id, "share", iso(base_time), rng.choice(["whatsapp", "whatsapp", "instagram", "copy_link"]), None, None, None))
        elif r2 < 0.135:
            signal_id += 1
            sig_rows.append((signal_id, imp_id, "comment", iso(base_time), None, None, None, None))
            comment_rows.append((signal_id, " ".join(rng.choice(WORDS) for _ in range(rng.randrange(2, 12))), None))
        elif r2 < 0.143:
            owner = video_owner[v]
            if (owner != u and user_state[owner] == "active" and user_state[u] == "active"
                    and (u, owner) not in follow_set and (u, owner) not in blocked_pairs):
                signal_id += 1
                sig_rows.append((signal_id, imp_id, "follow", iso(base_time), None, None, None, None))
                follow_set.add((u, owner))
                follow_from_feed.append((u, owner, iso(base_time), None, None))
        elif r2 < 0.150:
            signal_id += 1
            sig_rows.append((signal_id, imp_id, "not_interested", iso(base_time), None, None, None, None))
        elif r2 < 0.152:
            signal_id += 1
            sig_rows.append((signal_id, imp_id, "report", iso(base_time), None, None, None, rng.choice(["spam", "harassment", "misleading"])))
    cur.executemany("INSERT INTO view_segment VALUES (?, ?, ?, ?, ?)", seg_rows)
    cur.executemany("INSERT INTO engagement_signal VALUES (?, ?, ?, ?, ?, ?, ?, ?)", sig_rows)
    cur.executemany("INSERT INTO comment VALUES (?, ?, ?)", comment_rows)
    cur.executemany("INSERT OR IGNORE INTO follow VALUES (?, ?, ?, ?, ?)", follow_from_feed)

    con.commit()
    con.execute("ANALYZE")

    counts = {}
    for tbl in ["app_user", "auth_identity", "creator", "creator_tier_period", "audio_track", "video",
                "hashtag", "video_hashtag", "moderation_decision", "follow", "block", "mute",
                "impression", "view_segment", "engagement_signal", "comment", "agent_session",
                "agent_turn", "assistant_message", "tool_call", "recommendation", "judge_score",
                "user_rating", "inferred_interest_score", "model_price", "prompt_template_version"]:
        counts[tbl] = con.execute(f"SELECT count(*) FROM {tbl}").fetchone()[0]
    con.close()
    width = max(len(k) for k in counts)
    for k, v in counts.items():
        print(f"{k:<{width}}  {v:>9,}")
    print(f"\nLoaded in {time.time() - t0:.1f} s with seed {SEED}")


if __name__ == "__main__":
    main()

-- =====================================================================
-- Deliverable E.1: type-affinity check. Roll number GE26Z835.
-- Run against any database (it uses a temporary table only).
-- =====================================================================

CREATE TEMP TABLE affinity_probe (
    n_int   INTEGER,
    n_real  REAL,
    s_text  TEXT,
    d_time  DATETIME,          -- not a real type: NUMERIC affinity
    v_char  NVARCHAR(160)      -- not a real type: TEXT affinity
);

-- A text value that looks like a number is coerced; one that does not is
-- stored as TEXT regardless of the declared INTEGER type.
INSERT INTO affinity_probe VALUES ('42',    '3.5', 7,   '2026-03-03T14:32:07Z', 12345);
INSERT INTO affinity_probe VALUES ('hello', 'abc', 7.0, 'not a date',           'x');

SELECT n_int,  typeof(n_int)  AS t_int,
       n_real, typeof(n_real) AS t_real,
       s_text, typeof(s_text) AS t_text,
       d_time, typeof(d_time) AS t_time,
       v_char, typeof(v_char) AS t_char
FROM affinity_probe;

-- Expected:
--   row 1: 42|integer|3.5|real|7|text|2026-03-03T14:32:07Z|text|12345|text
--   row 2: hello|text|abc|text|7.0|text|not a date|text|x|text
-- 'hello' sat down in an INTEGER column without complaint. This is why
-- every numeric business rule in schema.sql is a CHECK, and why the two
-- columns where a stray string would be most damaging (duration_ms and
-- the timestamps) also check typeof() or a GLOB pattern.

-- Compare with a STRICT table: the same insert is rejected.
CREATE TEMP TABLE strict_probe (n_int INTEGER) STRICT;
INSERT INTO strict_probe VALUES ('42');       -- accepted: coercible text
INSERT INTO strict_probe VALUES ('hello');    -- Runtime error: cannot store TEXT value in INTEGER column
SELECT n_int, typeof(n_int) FROM strict_probe;

DROP TABLE affinity_probe;
DROP TABLE strict_probe;

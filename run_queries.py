"""
Runs every query block in queries.sql against scrollsense.db and writes
query_results.md with the row count, the first five rows and the
wall-clock runtime of each. Nothing is tuned: no extra indexes, no
PRAGMA changes, default cache.
"""

import re
import sqlite3
import time

DB_PATH = "scrollsense.db"
OUT_PATH = "query_results.md"

HEADER = re.compile(r"^-- (F\d+[a-z]?) · (.*)$")


def load_blocks():
    blocks = []
    current = None
    for line in open("queries.sql", encoding="utf-8"):
        m = HEADER.match(line.rstrip("\n"))
        if m:
            current = {"id": m.group(1), "title": m.group(2), "sql": []}
            blocks.append(current)
            continue
        if current is None:
            continue
        if line.startswith("--"):
            continue
        current["sql"].append(line)
    for b in blocks:
        b["sql"] = "".join(b["sql"]).strip()
    return [b for b in blocks if b["sql"]]


def main():
    con = sqlite3.connect(DB_PATH)
    con.execute("PRAGMA foreign_keys = ON")
    version = con.execute("SELECT sqlite_version()").fetchone()[0]
    out = [f"# Query results (SQLite {version})\n"]
    for b in load_blocks():
        cur = con.cursor()
        t0 = time.perf_counter()
        cur.execute(b["sql"])
        rows = cur.fetchall()
        ms = (time.perf_counter() - t0) * 1000
        cols = [d[0] for d in cur.description]
        out.append(f"\n## {b['id']} {b['title']}\n")
        out.append(f"Rows returned: {len(rows):,}    Runtime: {ms:,.0f} ms\n")
        out.append("| " + " | ".join(cols) + " |")
        out.append("|" + "---|" * len(cols))
        for r in rows[:5]:
            out.append("| " + " | ".join("" if v is None else str(v) for v in r) + " |")
        print(f"{b['id']:<5} rows={len(rows):>7,}  {ms:>8,.0f} ms")
    open(OUT_PATH, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"\nWritten to {OUT_PATH}")


if __name__ == "__main__":
    main()

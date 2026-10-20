"""
Run a PROVISIONAL SQL report file (sql/provisional/). The part before the line
"-- REPORT" sets up TEMP objects and runs as one batch; after it, each statement is preceded
by a "-- <title>" comment line and is printed as a tab-separated table.
The transaction is rolled back at the end, so nothing persists.

    python -m relayx.provisional_report sql/provisional/f1_matching_assessment.sql
    python -m relayx.provisional_report sql/provisional/f1b_additions.sql --setup sql/provisional/f1_matching_assessment.sql
"""
from __future__ import annotations

import argparse
import re
import sys
import time
from pathlib import Path

from .db import connect


def split_report(sql: str) -> tuple[str, list[tuple[str, str]]]:
    setup, _, report = sql.partition("\n-- REPORT\n")
    sections = []
    for block in re.split(r"\n\s*\n", report.strip()):
        lines = block.strip().splitlines()
        title = " ".join(l[2:].strip() for l in lines if l.startswith("--"))
        body = "\n".join(l for l in lines if not l.startswith("--")).strip().rstrip(";")
        if body:
            sections.append((title, body))
    return setup, sections


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("sql_file", type=Path)
    ap.add_argument("--setup", type=Path, action="append", default=[],
                    help="run the setup part of this report file first (repeatable), e.g. to reuse its TEMP objects")
    ap.add_argument("--env", default=".env")
    ap.add_argument("--timeout", type=int, default=300, help="statement timeout in seconds")
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)

    setup, sections = split_report(a.sql_file.read_text(encoding="utf-8-sig").replace("\r\n", "\n"))
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute(f"SET LOCAL statement_timeout = '{a.timeout}s'")
            for extra in a.setup:
                t0 = time.monotonic()
                cur.execute(split_report(extra.read_text(encoding="utf-8-sig").replace("\r\n", "\n"))[0])
                print(f"setup {extra.name}: {time.monotonic() - t0:.0f} s", file=sys.stderr, flush=True)
            t0 = time.monotonic()
            cur.execute(setup)
            print(f"setup: {time.monotonic() - t0:.0f} s", file=sys.stderr, flush=True)
            for title, body in sections:
                t0 = time.monotonic()
                cur.execute(body)
                print(f"## {title}")
                print("\t".join(d.name for d in cur.description))
                for row in cur.fetchall():
                    print("\t".join("" if v is None else str(v) for v in row))
                print(flush=True)
                print(f"{title[:40]}: {time.monotonic() - t0:.0f} s", file=sys.stderr, flush=True)
        conn.rollback()
    return 0


if __name__ == "__main__":
    sys.exit(main())

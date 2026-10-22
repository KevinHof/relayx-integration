"""
Value list for the F2 lookup run (docs/plans/2026-10-20-f2-covalo-lookup.md).

All distinct Covalo CAS, EC, INCI and NAME values under the F1 rules (setup part of
sql/provisional/f1_matching_assessment.sql, TEMP objects, read-only, rolled back), not only
values new to Relay X. One value per item. CAS and EC values failing the check digit go to a
separate list for local classification and are not queried.

    python -m relayx.lookup_values build [--out data/f2_lookup]

Writes <out>/<YYYYMMDD>/values.csv, excluded_check_digit.csv, build.json and SHA256SUMS.txt.
"""
from __future__ import annotations

import argparse
import csv
import io
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

from .db import connect
from .hashing import sha256_bytes
from .provisional_report import split_report

F1_SQL = Path("sql/provisional/f1_matching_assessment.sql")
PARAM = {"CAS": "cas", "EC": "ec", "INCI": "inci", "NAME": "name"}
TYPE_ORDER = {t: i for i, t in enumerate(PARAM)}
VALUE_COLS = ["seq", "id_type", "param", "value", "products", "in_replay", "in_catalogue"]
EXCLUDED_COLS = ["id_type", "value", "products", "in_replay", "in_catalogue", "reason"]


def split_values(rows: list[tuple]) -> tuple[list[dict], list[dict]]:
    """rows: (id_type, value, check_ok, products, in_replay, in_catalogue) from cov_val.
    Returns (items to query, excluded values), both in a fixed order: products descending,
    then type, then value."""
    rows = sorted(rows, key=lambda r: (-r[3], TYPE_ORDER[r[0]], r[1]))
    items, excluded = [], []
    for id_type, value, check_ok, products, in_replay, in_cat in rows:
        if id_type in ("CAS", "EC") and not check_ok:
            excluded.append({"id_type": id_type, "value": value, "products": products, "in_replay": in_replay,
                             "in_catalogue": in_cat, "reason": "check_digit"})
            continue
        items.append({"seq": len(items) + 1, "id_type": id_type, "param": PARAM[id_type], "value": value,
                      "products": products, "in_replay": in_replay, "in_catalogue": in_cat})
    return items, excluded


def to_csv(rows: list[dict], cols: list[str]) -> bytes:
    buf = io.StringIO(newline="")
    w = csv.DictWriter(buf, fieldnames=cols, lineterminator="\n")
    w.writeheader()
    w.writerows(rows)
    return buf.getvalue().encode("utf-8")


def read_values(path: Path) -> list[dict]:
    with path.open(encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["seq"], r["products"] = int(r["seq"]), int(r["products"])
    return rows


def fetch_rows() -> list[tuple]:
    setup = split_report(F1_SQL.read_text(encoding="utf-8-sig").replace("\r\n", "\n"))[0]
    with connect() as conn:
        with conn.cursor() as cur:
            cur.execute("SET LOCAL statement_timeout = '900s'")
            cur.execute(setup)
            cur.execute("SELECT id_type, value, check_ok, products, in_replay, in_catalogue FROM cov_val")
            rows = cur.fetchall()
        conn.rollback()
    return rows


def build(out: Path) -> dict:
    d = out / datetime.now(timezone.utc).strftime("%Y%m%d")
    if d.exists():
        raise SystemExit(f"{d} exists; value lists are never overwritten")
    items, excluded = split_values(fetch_rows())
    files = {"values.csv": to_csv(items, VALUE_COLS), "excluded_check_digit.csv": to_csv(excluded, EXCLUDED_COLS)}
    d.mkdir(parents=True)
    for name, data in files.items():
        (d / name).write_bytes(data)
    sums = {name: sha256_bytes(data) for name, data in files.items()}
    (d / "SHA256SUMS.txt").write_text("".join(f"{h}  {n}\n" for n, h in sums.items()), encoding="utf-8")
    info = {"built_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "source_sql": F1_SQL.as_posix(), "source_sql_sha256": sha256_bytes(F1_SQL.read_bytes()),
            "items": len(items), "excluded": len(excluded),
            "items_by_type": {t: sum(i["id_type"] == t for i in items) for t in PARAM},
            "excluded_by_type": {t: sum(e["id_type"] == t for e in excluded) for t in ("CAS", "EC")},
            "product_links_items": sum(i["products"] for i in items), "sha256": sums, "dir": d.as_posix()}
    (d / "build.json").write_text(json.dumps(info, indent=1), encoding="utf-8")
    return info


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["build"])
    ap.add_argument("--out", type=Path, default=Path("data/f2_lookup"))
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    print(json.dumps(build(a.out), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

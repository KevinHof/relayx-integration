"""
Statistics over a stored /changes replay run (reads raw pages only, writes nothing).

The feed is a knowledge log: one row per recorded version of an entry
(`changeKind` FIRST_RECORDED, SUPERSEDED or RETRACTED), oldest first. The
current state of an entry is its last row, unless that row is a retraction.

Usage:
    python -m relayx.replay_stats data/raw/changes_replay/<run_id> [--json out.json]
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import date
from pathlib import Path

ID_FIELDS = ("cas", "ec", "inci", "clpIndex", "colourIndex", "casList", "ecList", "inciList")
NAME_FIELDS = ("name", "nameEn", "nameLocal")


def load_rows(run_dir: Path) -> tuple[list[dict], list[dict]]:
    """(rows in feed order, page metas)."""
    metas = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(run_dir.glob("page_*.meta.json"))]
    rows: list[dict] = []
    for m in metas:
        if m["status"] != 200:
            continue
        body = json.loads((run_dir / f"page_{m['page_no']:05d}.json").read_text(encoding="utf-8"))
        rows.extend(body["changes"])
    return rows, metas


def has_identifier(row: dict) -> bool:
    ids = row.get("identifiers") or {}
    return any(ids.get(f) not in (None, "", []) for f in ID_FIELDS)


def has_name(row: dict) -> bool:
    ids = row.get("identifiers") or {}
    return any(ids.get(f) not in (None, "") for f in NAME_FIELDS)


def current_entries(rows: list[dict]) -> dict[str, dict]:
    """Last row per logicalEntryId in feed order, minus entries whose last row is RETRACTED."""
    last: dict[str, dict] = {}
    for r in rows:
        last[r["logicalEntryId"]] = r
    return {k: v for k, v in last.items() if v.get("changeKind") != "RETRACTED"}


def in_force(row: dict, today: str) -> bool:
    """Law time: false when an end date in the validity block has passed."""
    v = row.get("validity") or {}
    ends = [v.get("placingOnMarketUntil"), v.get("makingAvailableUntil")]
    return not any(e and e < today for e in ends)


def compute(rows: list[dict], metas: list[dict], today: str | None = None) -> dict:
    today = today or date.today().isoformat()
    ok = [m for m in metas if m["status"] == 200]
    by_id: dict[str, list[dict]] = {}
    for r in rows:
        by_id.setdefault(r["logicalEntryId"], []).append(r)

    no_first = [k for k, rs in by_id.items() if not any(r.get("changeKind") == "FIRST_RECORDED" for r in rs)]
    first_not_earliest = [k for k, rs in by_id.items()
                          if any(r.get("changeKind") == "FIRST_RECORDED" for r in rs)
                          and rs[0].get("changeKind") != "FIRST_RECORDED"]
    multi_first = [k for k, rs in by_id.items() if sum(r.get("changeKind") == "FIRST_RECORDED" for r in rs) > 1]
    keys = [(r["logicalEntryId"], r.get("knownSince")) for r in rows]
    ks = sorted(r["knownSince"] for r in rows if r.get("knownSince"))
    cur = current_entries(rows)
    cur_rows = list(cur.values())
    cur_in_force = [r for r in cur_rows if in_force(r, today)]

    def no_id_count(rs):
        return sum(1 for r in rs if not has_identifier(r))

    return {
        "pages": len(ok),
        "first_page_total": ok[0]["page"]["total"] if ok else None,
        "last_page_truncated": ok[-1]["page"]["truncated"] if ok else None,
        "sum_returned": sum(m["page"]["returned"] or 0 for m in ok),
        "total_rows": len(rows),
        "distinct_logicalEntryId": len(by_id),
        "duplicate_id_knownSince_pairs": len(keys) - len(set(keys)),
        "versions_per_entry": dict(sorted(Counter(len(v) for v in by_id.values()).items())),
        "changeKind": dict(Counter(r.get("changeKind") for r in rows)),
        "territory": dict(Counter(r.get("territory") for r in rows)),
        "knownSince_min": ks[0] if ks else None,
        "knownSince_max": ks[-1] if ks else None,
        "knownSince_null": sum(1 for r in rows if not r.get("knownSince")),
        "entries_without_FIRST_RECORDED": len(no_first),
        "entries_FIRST_RECORDED_not_earliest_row": len(first_not_earliest),
        "entries_with_multiple_FIRST_RECORDED": len(multi_first),
        "examples_without_FIRST_RECORDED": no_first[:10],
        "current_entries": len(cur_rows),
        "retracted_entries": len(by_id) - len(cur_rows),
        "current_in_force_today": len(cur_in_force),
        "current_by_annexType": dict(Counter(r.get("annexType") for r in cur_rows).most_common()),
        "current_by_entryScope": dict(Counter(r.get("entryScope") for r in cur_rows).most_common()),
        "current_by_annexRef": dict(Counter(r.get("annexRef") for r in cur_rows).most_common()),
        "current_no_identifier": no_id_count(cur_rows),
        "current_no_identifier_no_name": sum(1 for r in cur_rows if not has_identifier(r) and not has_name(r)),
        "current_no_identifier_by_entryScope": dict(Counter(r.get("entryScope") for r in cur_rows
                                                            if not has_identifier(r)).most_common()),
        "current_no_identifier_by_annexRef": dict(Counter(r.get("annexRef") for r in cur_rows
                                                          if not has_identifier(r)).most_common()),
        "current_in_force_no_identifier": no_id_count(cur_in_force),
        "all_rows_no_identifier": no_id_count(rows),
        "linkedSubstancesTruncated": sum(1 for r in cur_rows if r.get("linkedSubstancesTruncated")),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--json", type=Path)
    a = ap.parse_args(argv)
    rows, metas = load_rows(a.run_dir)
    stats = compute(rows, metas)
    text = json.dumps(stats, indent=1, ensure_ascii=False)
    print(text)
    if a.json:
        a.json.write_text(text, encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main())

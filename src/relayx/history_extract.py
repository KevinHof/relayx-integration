"""
Entry history extraction (/entries/{logicalEntryId}/history) and comparison with the
/changes rows already in raw.

Narrow option (default): entries with more than one version in the replay, plus entries
whose last row is RETRACTED. Ids are read from relayx_raw.entry_version, verbatim.

Usage:
    python -m relayx.history_extract run [--replay-run <run_id>]
    python -m relayx.history_extract compare <history_run_dir> [--replay-run <run_id>]
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from .api_extract import run_keyed
from .client import RelayXClient
from .db import connect

DEFAULT_REPLAY = "20261019T143522Z_eu"
NARROW_SQL = """
    SELECT logical_entry_id FROM relayx_raw.entry_version WHERE run_id = %(run)s
    GROUP BY logical_entry_id
    HAVING count(*) > 1 OR bool_or(change_kind = 'RETRACTED')
    ORDER BY logical_entry_id"""
# Keys that describe the feed or the knowledge window, not the entry content.
FEED_ONLY = {"changeKind", "changedFields", "knownSince"}
HISTORY_ONLY = {"knowledge", "changedFields"}


def narrow_ids(replay_run: str) -> list[str]:
    with connect() as c:
        return [r[0] for r in c.execute(NARROW_SQL, {"run": replay_run}).fetchall()]


def specs_for(ids: list[str]) -> list[dict]:
    return [{"endpoint": "/entries/{logicalEntryId}/history", "path": f"/entries/{i}/history",
             "source_ref": {"logicalEntryId": i}} for i in ids]


def compare(history_dir: Path, replay_run: str) -> dict:
    """Per entry: version counts, matching of history versions to feed rows by knownFrom =
    knownSince, keys present only on one side, and content differences of matched pairs."""
    with connect() as c:
        rows = c.execute("""SELECT logical_entry_id, known_since, change_kind, payload
                            FROM relayx_raw.entry_version WHERE run_id=%s ORDER BY page_no, row_no""",
                         (replay_run,)).fetchall()
    feed: dict[str, list[dict]] = {}
    for lid, _, _, payload in rows:
        feed.setdefault(lid, []).append(payload)

    out = Counter()
    hist_only_keys, feed_only_keys = Counter(), Counter()
    diff_fields = Counter()
    knowledge_values = Counter()
    examples = []
    for mp in sorted(history_dir.glob("call_*.meta.json")):
        meta = json.loads(mp.read_text(encoding="utf-8"))
        lid = meta["source_ref"]["logicalEntryId"]
        out[f"http_{meta['status']}"] += 1
        if meta["status"] != 200:
            examples.append({"logicalEntryId": lid, "status": meta["status"]})
            continue
        body = json.loads((history_dir / f"call_{meta['call_no']:05d}.json").read_bytes())
        versions = body.get("versions") or []
        frows = feed.get(lid, [])
        out["entries"] += 1
        out["versions_history"] += len(versions)
        out["rows_feed"] += len(frows)
        if body.get("truncated"):
            out["history_truncated"] += 1
        if len(versions) != len(frows):
            out["entries_count_differs"] += 1
            examples.append({"logicalEntryId": lid, "history_versions": len(versions), "feed_rows": len(frows),
                             "feed_kinds": [r.get("changeKind") for r in frows]})
        by_ks = {r.get("knownSince"): r for r in frows}
        for v in versions:
            k = v.get("knowledge") or {}
            knowledge_values["isCurrent=" + str(k.get("isCurrent"))] += 1
            knowledge_values["retracted=" + str(bool(k.get("retracted")))] += 1
            knowledge_values["supersessionNature=" + str(k.get("supersessionNature"))] += 1
            knowledge_values["coveredBy=" + str(bool(k.get("coveredBy")))] += 1
            f = by_ks.get(k.get("knownFrom"))
            if f is None:
                out["history_versions_unmatched"] += 1
                continue
            out["versions_matched"] += 1
            hist_only_keys.update(set(v) - set(f))
            feed_only_keys.update(set(f) - set(v))
            for key in (set(v) & set(f)) - FEED_ONLY - HISTORY_ONLY:
                if v[key] != f[key]:
                    diff_fields[key] += 1
    return {"summary": dict(out), "keys_only_in_history": dict(hist_only_keys),
            "keys_only_in_feed": dict(feed_only_keys), "content_fields_differing": dict(diff_fields),
            "knowledge_values": dict(knowledge_values), "examples": examples[:20]}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["run", "compare"])
    ap.add_argument("history_dir", type=Path, nargs="?")
    ap.add_argument("--replay-run", default=DEFAULT_REPLAY)
    ap.add_argument("--out", type=Path, default=Path("data/raw/api"))
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    if a.command == "run":
        ids = narrow_ids(a.replay_run)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        rd = a.out / f"{stamp}_history_narrow_eu"
        m = run_keyed(RelayXClient(), rd, "entries_history", specs_for(ids),
                      {"selection": "narrow", "replay_run": a.replay_run, "entries": len(ids)})
        print(json.dumps({k: m[k] for k in ("run_id", "status", "calls", "by_status", "units_requested")}))
        print("run dir:", rd)
    else:
        print(json.dumps(compare(a.history_dir, a.replay_run), indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

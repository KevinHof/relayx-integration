"""
Completeness check of a /changes replay against /substances/lookup:batch.

Draws a stratified random sample from kevin.relayx_eu_identifiers_v2 (Relay X's
own identifier catalogue, read-only), looks each item up on the EU market and
checks that every logicalEntryId lookup returns (in `constraints` and in
`upcoming`) exists in the replay. Raw batch responses go to
data/raw/completeness/<run_id>/ with their metadata; nothing is written to the DB.

Strata (by the first non-empty identifier column of a catalogue row):
    CAS        cas_number present                      -> query `cas`
    EC_ONLY    no CAS, ec_number present               -> query `ec`
    INCI_ONLY  no CAS or EC, inci_name present         -> query `inci`
    NAME_ONLY  none of the three, substance_name only  -> query `name`

Usage:
    python -m relayx.completeness <replay_run_dir> [--n CAS=100,EC_ONLY=50,INCI_ONLY=50,NAME_ONLY=10]
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
from datetime import datetime, timezone
from pathlib import Path

from .client import BATCH_MAX, RelayXClient
from .replay_stats import current_entries, load_rows

SEED = 20261019
LIMIT_PER_ITEM = 200
BATCH_RESULT_CAP = 2500  # observed server cap on items x limit per batch
DEFAULT_N = {"CAS": 100, "EC_ONLY": 50, "INCI_ONLY": 50, "NAME_ONLY": 10}
STRATUM_SQL = """
    select id, cas_number, ec_number, inci_name, substance_name,
           case when coalesce(trim(cas_number),'') <> '' then 'CAS'
                when coalesce(trim(ec_number),'')  <> '' then 'EC_ONLY'
                when coalesce(trim(inci_name),'')  <> '' then 'INCI_ONLY'
                when coalesce(trim(substance_name),'') <> '' then 'NAME_ONLY' end as stratum
    from kevin.relayx_eu_identifiers_v2 order by id"""
QUERY_FIELD = {"CAS": ("cas", "cas_number"), "EC_ONLY": ("ec", "ec_number"),
               "INCI_ONLY": ("inci", "inci_name"), "NAME_ONLY": ("name", "substance_name")}


def first_value(cell: str) -> str:
    """Catalogue cells hold several values separated by ' | '; query the first."""
    return next(p.strip() for p in cell.split("|") if p.strip())


def draw_sample(catalogue: list[dict], n: dict[str, int], seed: int = SEED) -> list[dict]:
    rng = random.Random(seed)
    out = []
    for stratum, k in n.items():
        pool = [r for r in catalogue if r["stratum"] == stratum]
        for r in rng.sample(pool, min(k, len(pool))):
            param, col = QUERY_FIELD[stratum]
            out.append({"stratum": stratum, "catalogue_id": r["id"], "param": param,
                        "value": first_value(r[col]),
                        "catalogue_row": {c: r[c] for c in ("cas_number", "ec_number", "inci_name", "substance_name")}})
    return out


def read_catalogue() -> list[dict]:
    import psycopg
    with psycopg.connect(os.environ["DATABASE_URL"]) as conn:
        conn.read_only = True
        with conn.cursor() as cur:
            cur.execute(STRATUM_SQL)
            cols = [d.name for d in cur.description]
            rows = [dict(zip(cols, r)) for r in cur.fetchall()]
        conn.rollback()
    return rows


def returned_entries(result: dict) -> list[dict]:
    """(logicalEntryId, block, annexRef, entryRef, name) for constraints and upcoming."""
    out = []
    for block, rows in (("constraints", result.get("constraints") or []),
                        ("upcoming", (result.get("upcoming") or {}).get("constraints") or [])):
        for c in rows:
            out.append({"logicalEntryId": c.get("logicalEntryId"), "block": block,
                        "annexRef": c.get("annexRef"), "entryRef": c.get("entryRef"),
                        "name": (c.get("identifiers") or {}).get("name") or c.get("name")})
    return out


def evaluate(sample: list[dict], results: dict[int, dict], current_ids: set[str], any_ids: set[str]) -> dict:
    """Per stratum: found / returned by lookup, plus every miss."""
    by = {}
    misses = []
    not_current = []
    item_notes = []
    for i, item in enumerate(sample):
        s = by.setdefault(item["stratum"], {"items": 0, "items_ok": 0, "items_with_rows": 0,
                                            "returned": 0, "found_current": 0, "found_any_version": 0,
                                            "items_paged": 0})
        s["items"] += 1
        res = results.get(i)
        if not res or not res.get("ok"):
            item_notes.append({"index": i, **item, "note": "not ok", "error": (res or {}).get("error")})
            continue
        s["items_ok"] += 1
        if (res.get("total") or 0) > (res.get("returned") or 0) or res.get("scanCapped"):
            s["items_paged"] += 1
            item_notes.append({"index": i, "stratum": item["stratum"], "value": item["value"],
                               "note": "more rows than returned", "total": res.get("total"),
                               "returned": res.get("returned"), "scanCapped": res.get("scanCapped")})
        rows = returned_entries(res)
        if rows:
            s["items_with_rows"] += 1
        for r in rows:
            s["returned"] += 1
            lid = r["logicalEntryId"]
            if lid in current_ids:
                s["found_current"] += 1
            if lid in any_ids:
                s["found_any_version"] += 1
            else:
                misses.append({"stratum": item["stratum"], "param": item["param"], "value": item["value"],
                               "catalogue_id": item["catalogue_id"], "catalogue_row": item["catalogue_row"], **r})
            if lid in any_ids and lid not in current_ids:
                not_current.append({"stratum": item["stratum"], "param": item["param"],
                                    "value": item["value"], **r})
    for s in by.values():
        s["rate_any_version"] = round(s["found_any_version"] / s["returned"], 4) if s["returned"] else None
        s["rate_current"] = round(s["found_current"] / s["returned"], 4) if s["returned"] else None
    tot = {k: sum(s[k] for s in by.values()) for k in ("items", "items_ok", "items_with_rows", "returned",
                                                       "found_current", "found_any_version", "items_paged")}
    tot["rate_any_version"] = round(tot["found_any_version"] / tot["returned"], 4) if tot["returned"] else None
    tot["rate_current"] = round(tot["found_current"] / tot["returned"], 4) if tot["returned"] else None
    return {"by_stratum": by, "total": tot, "misses": misses, "found_not_current": not_current,
            "item_notes": item_notes}


def fetch(client: RelayXClient, sample: list[dict], out_dir: Path, limit: int = LIMIT_PER_ITEM) -> dict[int, dict]:
    """Batch the sample; re-queue items a truncated batch left unevaluated.

    The server refuses a batch whose items x limit exceeds 2,500 (400
    batch_result_too_large, not stated in the contract). Units are charged per
    item, so smaller batches cost the same quota."""
    size = max(1, min(BATCH_MAX, BATCH_RESULT_CAP // limit))
    results: dict[int, dict] = {}
    queue = list(range(len(sample)))
    call = 0
    while queue:
        chunk, queue = queue[:size], queue[size:]
        call += 1
        items = [{sample[i]["param"]: sample[i]["value"]} for i in chunk]
        r = client.lookup_batch(items, territory="EU", view="summary", limit=limit)
        (out_dir / f"batch_{call:03d}.json").write_bytes(r.raw)
        (out_dir / f"batch_{call:03d}.meta.json").write_text(
            json.dumps(r.meta() | {"sample_indices": chunk}, indent=1), encoding="utf-8")
        if not r.ok:
            raise RuntimeError(f"batch {call}: HTTP {r.status}: {str(r.data)[:300]}")
        seen = set()
        for res in r.data.get("results") or []:
            idx = chunk[res["index"]]
            results[idx] = res
            seen.add(idx)
        unevaluated = [i for i in chunk if i not in seen]
        if unevaluated:
            print(f"  batch {call}: {len(unevaluated)} items unevaluated "
                  f"(truncated={r.data.get('truncated')}), re-queued", flush=True)
            queue = unevaluated + queue
    return results


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("replay_run_dir", type=Path)
    ap.add_argument("--n", default=",".join(f"{k}={v}" for k, v in DEFAULT_N.items()))
    ap.add_argument("--out", type=Path, default=Path("data/raw/completeness"))
    ap.add_argument("--seed", type=int, default=SEED)
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)

    n = {k: int(v) for k, v in (p.split("=") for p in a.n.split(","))}
    rows, _ = load_rows(a.replay_run_dir)
    any_ids = {r["logicalEntryId"] for r in rows}
    current_ids = set(current_entries(rows))
    sample = draw_sample(read_catalogue(), n, a.seed)

    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = a.out / stamp
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "sample.json").write_text(json.dumps({"seed": a.seed, "n": n, "items": sample},
                                                    indent=1, ensure_ascii=False), encoding="utf-8")
    client = RelayXClient()
    results = fetch(client, sample, out_dir)
    report = evaluate(sample, results, current_ids, any_ids) | {
        "replay_run": a.replay_run_dir.name, "seed": a.seed, "n": n,
        "requests": client.requests_sent, "units_used_from_headers": client.quota.units_from_headers}
    (out_dir / "report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
    print(json.dumps({k: report[k] for k in ("by_stratum", "total", "requests", "units_used_from_headers")}, indent=1))
    print("misses:", len(report["misses"]), "| item notes:", len(report["item_notes"]), "| out:", out_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())

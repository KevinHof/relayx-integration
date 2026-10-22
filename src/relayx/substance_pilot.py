"""
Redundancy pilot for the per-substance endpoints (roadmap phase 2b, Kevin 2026-10-19).

About 100 substances from Relay X's identifier catalogue, stratified like the completeness
check (CAS, EC_ONLY, INCI_ONLY, NAME_ONLY), each sent through every per-substance endpoint:
lookup (via lookup:batch, view=full, context on, territory EU), market-summary,
impurity-limits, screening and opinions. Name-only items are not sent to screening and
opinions, which do not accept `name`; they are recorded as NOT_QUERYABLE.

Usage:
    python -m relayx.substance_pilot run
    python -m relayx.substance_pilot run --resume <run_dir>

The same command runs the F2 Covalo lookup (relayx.covalo_lookup, runbook section 5a):
    python -m relayx.substance_pilot preflight
    python -m relayx.substance_pilot lookup [--values CSV] [--rate-per-minute N] [--max-units N]
                                            [--max-items N] [--dry-run] [--resume <run_dir>]
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from .api_extract import resume_keyed, run_keyed
from .client import RelayXClient
from .completeness import draw_sample, read_catalogue

SEED = 20261020
N = {"CAS": 40, "EC_ONLY": 20, "INCI_ONLY": 20, "NAME_ONLY": 20}
BATCH_ITEMS, BATCH_LIMIT = 25, 100           # view=full cap 25 items; 25 x 100 = 2,500 cap
GET_ENDPOINTS = ["/substances/market-summary", "/substances/impurity-limits",
                 "/substances/screening", "/substances/opinions"]
NO_NAME = {"/substances/screening", "/substances/opinions"}


def build_specs(sample: list[dict]) -> tuple[list[dict], list[dict]]:
    specs, not_queryable = [], []
    for start in range(0, len(sample), BATCH_ITEMS):
        idx = list(range(start, min(start + BATCH_ITEMS, len(sample))))
        specs.append({"endpoint": "/substances/lookup:batch", "path": "/substances/lookup:batch",
                      "method": "POST", "units": len(idx),
                      "body": {"items": [{sample[i]["param"]: sample[i]["value"]} for i in idx],
                               "territory": "EU", "view": "full", "limit": BATCH_LIMIT},
                      "source_ref": [{"sample_index": i, "stratum": sample[i]["stratum"]} for i in idx]})
    for ep in GET_ENDPOINTS:
        for i, item in enumerate(sample):
            ref = {"sample_index": i, "stratum": item["stratum"]}
            if item["param"] == "name" and ep in NO_NAME:
                not_queryable.append({"endpoint": ep, **ref, "reason": "name not accepted"})
                continue
            specs.append({"endpoint": ep, "path": ep, "params": {item["param"]: item["value"]}, "source_ref": ref})
    return specs, not_queryable


LIST_KEY = {"/substances/market-summary": "markets", "/substances/impurity-limits": "limits",
            "/substances/screening": "listings", "/substances/opinions": "opinions"}
CONTEXT_KEY = {"/substances/screening": "screeningLists", "/substances/opinions": "scientificOpinions"}


def _item_key(x: dict) -> str:
    """Identity of an opinion or screening item for comparison across endpoints: the
    fields both shapes are expected to share, else the whole item."""
    for fields in (("body", "reference"), ("list", "listedRef"), ("list",)):
        if all(f in x for f in fields):
            return "|".join(str(x[f]) for f in fields)
    return json.dumps(x, sort_keys=True, ensure_ascii=False)


def analyse(run_dir: Path) -> dict:
    sample = json.loads((run_dir / "sample.json").read_text(encoding="utf-8"))
    items = sample["items"]
    lookup: dict[int, dict] = {}
    per_ep: dict[str, dict[int, dict]] = {ep: {} for ep in GET_ENDPOINTS}
    statuses: dict[str, Counter] = {}
    for mp in sorted(run_dir.glob("call_*.meta.json")):
        meta = json.loads(mp.read_text(encoding="utf-8"))
        body = json.loads((run_dir / f"call_{meta['call_no']:05d}.json").read_bytes())
        ep = meta["endpoint"]
        statuses.setdefault(ep, Counter())[str(meta["status"])] += 1
        if ep.endswith(":batch"):
            for res in body.get("results") or []:
                lookup[meta["source_ref"][res["index"]]["sample_index"]] = res
        else:
            per_ep[ep][meta["source_ref"]["sample_index"]] = body

    rep: dict = {"http_status": {k: dict(v) for k, v in statuses.items()},
                 "not_queryable": Counter(f"{x['endpoint']}|{x['stratum']}" for x in sample["not_queryable"])}
    # lookup
    lk = Counter()
    ctx = Counter()
    for i, it in enumerate(items):
        s = it["stratum"]
        r = lookup.get(i)
        if not r or not r.get("ok"):
            lk[f"{s}|not_ok"] += 1
            continue
        lk[f"{s}|status={(r.get('ingredientStatus') or {}).get('status')}"] += 1
        if r.get("constraints"):
            lk[f"{s}|with_constraints"] += 1
        if (r.get("total") or 0) > (r.get("returned") or 0) or r.get("scanCapped"):
            lk[f"{s}|more_rows_than_returned"] += 1
        for k, v in (r.get("substanceContext") or {}).items():
            if (v or {}).get("items"):
                ctx[f"{k}|{s}"] += 1
    rep["lookup"] = dict(sorted(lk.items()))
    rep["lookup_context_nonempty_by_block_stratum"] = dict(sorted(ctx.items()))

    # opinions and screening: separate endpoint vs lookup substanceContext
    for ep, ck in CONTEXT_KEY.items():
        c = Counter()
        diffs = []
        for i, it in enumerate(items):
            if i not in per_ep[ep]:
                continue
            s = it["stratum"]
            ep_items = per_ep[ep][i].get(LIST_KEY[ep]) or []
            r = lookup.get(i) or {}
            lk_items = ((r.get("substanceContext") or {}).get(ck) or {}).get("items") or []
            a, b = {_item_key(x) for x in ep_items}, {_item_key(x) for x in lk_items}
            c[f"{s}|queried"] += 1
            c[f"{s}|endpoint_nonempty"] += bool(a)
            c[f"{s}|lookup_nonempty"] += bool(b)
            c[f"{s}|endpoint_items"] += len(a)
            c[f"{s}|lookup_items"] += len(b)
            c[f"{s}|items_both"] += len(a & b)
            if a != b:
                c[f"{s}|substances_differ"] += 1
                diffs.append({"value": it["value"], "only_endpoint": sorted(a - b)[:5], "only_lookup": sorted(b - a)[:5],
                              "endpoint_item_keys": sorted(ep_items[0]) if ep_items else None,
                              "lookup_item_keys": sorted(lk_items[0]) if lk_items else None})
            if per_ep[ep][i].get("substanceKnown") is False:
                c[f"{s}|substanceKnown_false"] += 1
        rep[ep] = {"counts": dict(sorted(c.items())), "differences": diffs[:10]}

    # impurity limits: no counterpart in lookup
    c = Counter()
    regimes, verif = Counter(), Counter()
    for i, it in enumerate(items):
        b = per_ep["/substances/impurity-limits"].get(i)
        if b is None:
            continue
        rows = b.get("limits") or []
        c[f"{it['stratum']}|queried"] += 1
        c[f"{it['stratum']}|nonempty"] += bool(rows)
        c[f"{it['stratum']}|substanceKnown_false"] += b.get("substanceKnown") is False
        for x in rows:
            regimes[x.get("regime")] += 1
            verif[x.get("verificationLevel")] += 1
    rep["/substances/impurity-limits"] = {"counts": dict(sorted(c.items())), "regime": dict(regimes),
                                          "verificationLevel": dict(verif)}

    # market-summary vs lookup constraints
    c = Counter()
    market_keys = Counter()
    mismatches = []
    for i, it in enumerate(items):
        b = per_ep["/substances/market-summary"].get(i)
        if b is None:
            continue
        s = it["stratum"]
        markets = b.get("markets") or []
        c[f"{s}|queried"] += 1
        c[f"{s}|markets_nonempty"] += bool(markets)
        r = lookup.get(i) or {}
        lk_total = r.get("total")
        lk_refs = {f"{x.get('annexRef')} {x.get('entryRef')}" for x in r.get("constraints") or []}
        for m in markets:
            market_keys.update(m.keys())
            c[f"{s}|status={m.get('status')}"] += 1
            if m.get("territory") != "EU":
                continue
            same_count = m.get("constraintCount") == lk_total
            same_refs = set(m.get("entryRefs") or []) == lk_refs
            c[f"{s}|EU_count_equals_lookup_total"] += same_count
            c[f"{s}|EU_entryRefs_equal_lookup_refs"] += same_refs
            if not (same_count and same_refs) and len(mismatches) < 10:
                mismatches.append({"value": it["value"], "ms_count": m.get("constraintCount"), "lookup_total": lk_total,
                                   "ms_only_refs": sorted(set(m.get("entryRefs") or []) - lk_refs)[:5],
                                   "lookup_only_refs": sorted(lk_refs - set(m.get("entryRefs") or []))[:5]})
    rep["/substances/market-summary"] = {"counts": dict(sorted(c.items())), "market_row_keys": dict(market_keys),
                                         "mismatches": mismatches}
    rep["not_queryable"] = dict(rep["not_queryable"])
    return rep


def lookup_main(a) -> int:
    """F2 Covalo lookup run (relayx.covalo_lookup): new run, --resume or --dry-run."""
    from . import covalo_lookup as cl
    from .lookup_values import read_values
    if a.resume:
        prev = json.loads((a.resume / "manifest.json").read_text(encoding="utf-8"))
        if prev.get("feed") != cl.FEED:
            raise SystemExit(f"{a.resume} is not a {cl.FEED} run")
        p = prev["params"]
        values_file, max_items = Path(p["values_file"]), p["max_items"]
        rate = a.rate_per_minute or p["rate_per_minute"]
        max_units = a.max_units or p["max_units"]
        rd = a.resume
    else:
        values_file, max_items = a.values, a.max_items
        rate, max_units = a.rate_per_minute or 60, a.max_units or 24000
        rd = None
    if rate > cl.MAX_RATE:
        raise SystemExit(f"--rate-per-minute may not exceed {cl.MAX_RATE}")
    cfg = cl.Config(rate_per_minute=rate, max_units=max_units, max_items=max_items)
    values = read_values(values_file)
    if a.dry_run:
        print(json.dumps(cl.dry_run(values, cfg) | {"values_file": values_file.as_posix()}, indent=1))
        return 0
    if rd is None:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        rd = a.out / f"{stamp}_covalo_lookup_eu" if not max_items else a.out / f"{stamp}_covalo_lookup_eu_canary{max_items}"
    m = cl.LookupRun(rd, values, values_file, cfg).run()
    if m["stop_reason"] == "interrupted (Ctrl+C)":
        return 130
    return 0 if m["status"] == "complete" else 1


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["run", "analyse", "lookup", "preflight"],
                    help="run/analyse: redundancy pilot; lookup: F2 Covalo lookup run; preflight: 1-unit quota check")
    ap.add_argument("run_dir", type=Path, nargs="?")
    ap.add_argument("--out", type=Path, default=Path("data/raw/api"))
    ap.add_argument("--resume", type=Path, metavar="RUN_DIR", help="continue this run (pilot or lookup)")
    ap.add_argument("--env", type=Path, default=Path(".env"))
    ap.add_argument("--values", type=Path, default=Path("data/f2_lookup/20261022/values.csv"),
                    help="lookup: value list (relayx.lookup_values)")
    ap.add_argument("--rate-per-minute", type=int, help="lookup: units per 60 s, default 60, at most 300")
    ap.add_argument("--max-units", type=int, help="lookup: hard unit cap, default 24000")
    ap.add_argument("--max-items", type=int, help="lookup: canary on the first N items of the value list")
    ap.add_argument("--dry-run", action="store_true", help="lookup: plan only, no API call")
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    if a.command == "lookup":
        return lookup_main(a)
    if a.command == "preflight":
        from .covalo_lookup import preflight
        info = preflight(a.out)
        print(json.dumps(info, indent=1))
        return 0 if info["status"] == 200 else 1
    if a.command == "analyse":
        print(json.dumps(analyse(a.run_dir), indent=1, ensure_ascii=False, default=str))
        return 0
    if a.resume:
        m = resume_keyed(RelayXClient(), a.resume, "substance_pilot")
        print(json.dumps({k: m[k] for k in ("run_id", "status", "calls", "by_status", "units_requested")}))
        print("run dir:", a.resume)
        return 0
    sample = draw_sample(read_catalogue(), N, SEED)
    specs, not_queryable = build_specs(sample)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    rd = a.out / f"{stamp}_substance_pilot_eu"
    rd.mkdir(parents=True, exist_ok=True)
    (rd / "sample.json").write_text(json.dumps({"seed": SEED, "n": N, "items": sample,
                                                "not_queryable": not_queryable}, indent=1, ensure_ascii=False),
                                    encoding="utf-8")
    m = run_keyed(RelayXClient(), rd, "substance_pilot", specs,
                  {"seed": SEED, "n": N, "territory": "EU", "lookup_view": "full", "lookup_limit": BATCH_LIMIT})
    print(json.dumps({k: m[k] for k in ("run_id", "status", "calls", "by_status", "units_requested")}))
    print("run dir:", rd)
    return 0


if __name__ == "__main__":
    sys.exit(main())

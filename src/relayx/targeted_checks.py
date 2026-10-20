"""
Targeted checks approved 2026-10-20 (about 140 units), EU territory:

- opinions: about 50 substances by CAS: 25 from Article 15 entries (whose condition text
  names the SCCS) and 25 from Cosmetics Annexes III, V and VI (no entry there names the SCCS;
  stratum added because these annexes are where SCCS opinions are expected). Each substance
  goes through lookup:batch (view=full) and /substances/opinions; lookup's
  substanceContext.scientificOpinions is compared with the endpoint.
- impurity: 20 known contaminants by CAS through /substances/impurity-limits.
- ifra: 20 fragrance allergens (/allergens, with CAS) through /substances/screening, to see
  whether list code IFRA_STANDARDS appears.

Each check is one keyed run in data/raw/api/<stamp>_check_<name>_eu/ with sample.json.

Usage:
    python -m relayx.targeted_checks run opinions|impurity|ifra [--resume <run_dir>]
    python -m relayx.targeted_checks analyse <run_dir>
"""
from __future__ import annotations

import argparse
import json
import random
import sys
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

from .api_extract import resume_keyed, run_keyed
from .client import RelayXClient
from .db import connect

SEED = 20261020
REPLAY_RUN = "20261019T143522Z_eu"
ALLERGENS_RUN = "20261019T174201Z_allergens_eu"
BATCH_ITEMS, BATCH_LIMIT = 25, 100
CAS_RE = r"^\d{2,7}-\d{2}-\d$"

# Known contaminants (CAS verified by check digit in tests).
CONTAMINANTS = [
    ("lead", "7439-92-1"), ("cadmium", "7440-43-9"), ("mercury", "7439-97-6"),
    ("arsenic", "7440-38-2"), ("nickel", "7440-02-0"), ("chromium(VI)", "18540-29-9"),
    ("antimony", "7440-36-0"), ("1,4-dioxane", "123-91-1"), ("methanol", "67-56-1"),
    ("formaldehyde", "50-00-0"), ("N-nitrosodimethylamine", "62-75-9"),
    ("N-nitrosodiethylamine", "55-18-5"), ("N-nitrosodiethanolamine", "1116-54-7"),
    ("acrylamide", "79-06-1"), ("benzene", "71-43-2"), ("ethylene oxide", "75-21-8"),
    ("diethylene glycol", "111-46-6"), ("asbestos", "1332-21-4"),
    ("benzo[a]pyrene", "50-32-8"), ("dichloromethane", "75-09-2"),
]

OPINION_STRATA = {"ARTICLE_15": (["Article 15(1)", "Article 15(2)"], 25),
                  "ANNEX_III_V_VI": (["Annex III", "Annex V", "Annex VI"], 25)}


def cas_ok(cas: str) -> bool:
    digits = cas.replace("-", "")
    body, check = digits[:-1], int(digits[-1])
    return sum(int(d) * w for w, d in enumerate(reversed(body), start=1)) % 10 == check


def _current_single_cas(annexes: list[str]) -> list[dict]:
    """Current entries of these annexes whose printed CAS is a single number; one item per CAS."""
    sql = """
        SELECT DISTINCT ON (payload -> 'identifiers' ->> 'cas')
               payload -> 'identifiers' ->> 'cas', payload ->> 'annexRef', payload ->> 'entryRef', logical_entry_id
        FROM relayx_raw.entry_version
        WHERE run_id = %(run)s AND payload ->> 'annexRef' = ANY(%(annexes)s)
          AND payload -> 'identifiers' ->> 'cas' ~ %(re)s
          AND logical_entry_id NOT IN (SELECT logical_entry_id FROM relayx_raw.entry_version
                                       WHERE run_id = %(run)s AND change_kind = 'RETRACTED')
        ORDER BY payload -> 'identifiers' ->> 'cas', logical_entry_id"""
    with connect() as c:
        rows = c.execute(sql, {"run": REPLAY_RUN, "annexes": annexes, "re": CAS_RE}).fetchall()
    return [{"cas": r[0], "annexRef": r[1], "entryRef": r[2], "logicalEntryId": r[3]} for r in rows]


def sample_opinions(rng: random.Random) -> list[dict]:
    out = []
    for stratum, (annexes, n) in OPINION_STRATA.items():
        pool = [x for x in _current_single_cas(annexes) if x["cas"] not in {o["cas"] for o in out}]
        out += [x | {"stratum": stratum} for x in rng.sample(pool, min(n, len(pool)))]
    return out


def sample_ifra(rng: random.Random, n: int = 20) -> list[dict]:
    with connect() as c:
        rows = c.execute("""
            SELECT a ->> 'cas', a ->> 'name', a ->> 'entryRef'
            FROM relayx_raw.api_response r, jsonb_array_elements(r.body -> 'allergens') a
            WHERE r.run_id = %s AND r.http_status = 200 AND a ->> 'cas' ~ %s
            ORDER BY a ->> 'cas'""", (ALLERGENS_RUN, CAS_RE)).fetchall()
    pool = list({r[0]: {"cas": r[0], "name": r[1], "entryRef": r[2], "stratum": "ALLERGEN"} for r in rows}.values())
    return rng.sample(pool, min(n, len(pool)))


def build_specs(check: str, items: list[dict]) -> list[dict]:
    specs = []
    if check == "opinions":
        for start in range(0, len(items), BATCH_ITEMS):
            idx = list(range(start, min(start + BATCH_ITEMS, len(items))))
            specs.append({"endpoint": "/substances/lookup:batch", "path": "/substances/lookup:batch",
                          "method": "POST", "units": len(idx),
                          "body": {"items": [{"cas": items[i]["cas"]} for i in idx],
                                   "territory": "EU", "view": "full", "limit": BATCH_LIMIT},
                          "source_ref": [{"sample_index": i, "stratum": items[i]["stratum"]} for i in idx]})
    endpoint = {"opinions": "/substances/opinions", "impurity": "/substances/impurity-limits",
                "ifra": "/substances/screening"}[check]
    for i, it in enumerate(items):
        specs.append({"endpoint": endpoint, "path": endpoint, "params": {"cas": it["cas"]},
                      "source_ref": {"sample_index": i, "stratum": it["stratum"]}})
    return specs


def items_for(check: str) -> list[dict]:
    rng = random.Random(SEED)
    if check == "opinions":
        return sample_opinions(rng)
    if check == "ifra":
        return sample_ifra(rng)
    return [{"cas": cas, "name": name, "stratum": "CONTAMINANT"} for name, cas in CONTAMINANTS]


def _calls(run_dir: Path):
    for mp in sorted(run_dir.glob("call_*.meta.json")):
        meta = json.loads(mp.read_text(encoding="utf-8"))
        body = json.loads((run_dir / f"call_{meta['call_no']:05d}.json").read_bytes())
        yield meta, body


def _opinion_key(x: dict) -> str:
    return f"{x.get('body')}|{x.get('reference')}"


def analyse(run_dir: Path) -> dict:
    sample = json.loads((run_dir / "sample.json").read_text(encoding="utf-8"))
    items, check = sample["items"], sample["check"]
    status = Counter()
    lookup, ep = {}, {}
    for meta, body in _calls(run_dir):
        status[f"{meta['endpoint']}|{meta['status']}"] += 1
        if meta["endpoint"].endswith(":batch"):
            for res in body.get("results") or []:
                lookup[meta["source_ref"][res["index"]]["sample_index"]] = res
        else:
            ep[meta["source_ref"]["sample_index"]] = body
    rep: dict = {"check": check, "items": len(items), "http_status": dict(status)}

    if check == "opinions":
        c, bodies_ep, bodies_lk, rows = Counter(), Counter(), Counter(), []
        for i, it in enumerate(items):
            s = it["stratum"]
            b = ep.get(i) or {}
            r = lookup.get(i) or {}
            a = {_opinion_key(x) for x in b.get("opinions") or []}
            lk = ((r.get("substanceContext") or {}).get("scientificOpinions") or {}).get("items") or []
            k = {_opinion_key(x) for x in lk}
            bodies_ep.update(f"{s}|{x.get('body')}" for x in b.get("opinions") or [])
            bodies_lk.update(f"{s}|{x.get('body')}" for x in lk)
            c[f"{s}|queried"] += 1
            c[f"{s}|substanceKnown_false"] += b.get("substanceKnown") is False
            c[f"{s}|lookup_status={(r.get('ingredientStatus') or {}).get('status')}"] += 1
            c[f"{s}|endpoint_nonempty"] += bool(a)
            c[f"{s}|lookup_nonempty"] += bool(k)
            c[f"{s}|equal"] += a == k
            c[f"{s}|endpoint_items"] += len(a)
            c[f"{s}|lookup_items"] += len(k)
            if a != k:
                rows.append({"cas": it["cas"], "only_endpoint": sorted(a - k), "only_lookup": sorted(k - a)})
        rep |= {"counts": dict(sorted(c.items())), "bodies_endpoint": dict(bodies_ep),
                "bodies_lookup": dict(bodies_lk), "differences": rows}
    elif check == "impurity":
        rows = []
        for i, it in enumerate(items):
            b = ep.get(i) or {}
            lim = b.get("limits") or []
            rows.append({"name": it["name"], "cas": it["cas"], "substanceKnown": b.get("substanceKnown"),
                         "limits": len(lim),
                         "markets": sorted({x.get("territory") or x.get("market") or "?" for x in lim}),
                         "regimes": sorted({str(x.get("regime")) for x in lim})})
        rep |= {"with_limits": sum(r["limits"] > 0 for r in rows),
                "substance_known": sum(r["substanceKnown"] is True for r in rows), "rows": rows}
    else:
        codes, rows = Counter(), []
        for i, it in enumerate(items):
            b = ep.get(i) or {}
            lst = [x.get("list") for x in b.get("listings") or []]
            codes.update(lst)
            rows.append({"cas": it["cas"], "name": it["name"], "substanceKnown": b.get("substanceKnown"),
                         "lists": lst})
        rep |= {"list_codes": dict(codes), "ifra_standards": codes.get("IFRA_STANDARDS", 0),
                "substance_known": sum(r["substanceKnown"] is True for r in rows), "rows": rows}
    return rep


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["run", "analyse"])
    ap.add_argument("target", help="check name (run) or run directory (analyse)")
    ap.add_argument("--resume", type=Path, metavar="RUN_DIR")
    ap.add_argument("--out", type=Path, default=Path("data/raw/api"))
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    if a.command == "analyse":
        print(json.dumps(analyse(Path(a.target)), indent=1, ensure_ascii=False))
        return 0
    if a.target not in ("opinions", "impurity", "ifra"):
        ap.error("check must be opinions, impurity or ifra")
    feed = f"check_{a.target}"
    if a.resume:
        rd, m = a.resume, resume_keyed(RelayXClient(), a.resume, feed)
    else:
        items = items_for(a.target)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        rd = a.out / f"{stamp}_{feed}_eu"
        rd.mkdir(parents=True, exist_ok=True)
        (rd / "sample.json").write_text(json.dumps({"check": a.target, "seed": SEED, "items": items},
                                                   indent=1, ensure_ascii=False), encoding="utf-8")
        specs = build_specs(a.target, items)
        m = run_keyed(RelayXClient(), rd, feed, specs,
                      {"check": a.target, "seed": SEED, "territory": "EU", "items": len(items)})
    print(json.dumps({k: m[k] for k in ("run_id", "status", "calls", "by_status", "units_requested")}))
    print("run dir:", rd)
    return 0 if m["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())

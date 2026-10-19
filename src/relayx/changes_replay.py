"""
Phase 1 extractor: replay GET /changes from an early `since`, paged by cursor.

Layout of one run (append-only, nothing is overwritten):
    <out>/<run_id>/page_00001.json        raw response bytes
    <out>/<run_id>/page_00001.meta.json   request params, timestamp, status, hashes,
                                          rate headers, paging fields of the page
    <out>/<run_id>/manifest.json          run id, params, start/end time, pages, rows,
                                          units used, last and final cursor, status

The page meta files are the source of truth. The manifest is rewritten after
every page and can be rebuilt from them; resuming reads the meta files, takes
the `nextCursor` of the last stored 200 page and continues from there.

Usage:
    python -m relayx.changes_replay --territory EU --since 2000-01-01T00:00:00Z
    python -m relayx.changes_replay --resume data/raw/changes_replay/<run_id>
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from .client import RelayXClient, utc_now

DEFAULT_OUT = Path("data/raw/changes_replay")
PAGE_LIMIT = 200


class ReplayError(RuntimeError):
    pass


def _write_json(path: Path, obj: dict) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


def stored_pages(run_dir: Path) -> list[dict]:
    """Meta of every stored page, in page order."""
    return [json.loads(p.read_text(encoding="utf-8"))
            for p in sorted(run_dir.glob("page_*.meta.json"))]


def _manifest(run_dir: Path, params: dict, started_at: str, status: str, client: RelayXClient | None,
              units_before: int) -> dict:
    pages = [m for m in stored_pages(run_dir) if m["status"] == 200]
    last = pages[-1] if pages else None
    prev = {}
    mpath = run_dir / "manifest.json"
    if mpath.exists():
        prev = json.loads(mpath.read_text(encoding="utf-8"))
    units = units_before + (client.quota.units_from_headers if client else 0)
    return {
        "run_id": run_dir.name,
        "endpoint": "GET /api/regulatory/v1/changes",
        "params": params,
        "started_at": started_at,
        "updated_at": utc_now(),
        "finished_at": utc_now() if status == "complete" else None,
        "status": status,
        "pages": len(pages),
        "rows": sum(m["page"]["returned"] or 0 for m in pages),
        "first_page_total": pages[0]["page"]["total"] if pages else None,
        "requests": prev.get("requests_before", 0) + (client.requests_sent if client else 0),
        "requests_before": prev.get("requests_before", 0),
        "units_used_from_headers": units,
        "units_before": units_before,
        "resumed_count": prev.get("resumed_count", 0),
        "last_cursor": last["page"]["nextCursor"] if last else None,
        "last_next_since": last["page"]["nextSince"] if last else None,
        "final_cursor": last["page"]["nextCursor"] if status == "complete" and last else None,
        "last_rate": last["rate"] if last else None,
    }


def run(client: RelayXClient, run_dir: Path, since: str, territory: str | None,
        limit: int = PAGE_LIMIT, max_pages: int | None = None) -> dict:
    """Fetch pages until `truncated` is false. Resumes if run_dir already holds pages."""
    run_dir.mkdir(parents=True, exist_ok=True)
    params = {"since": since, "territory": territory, "limit": limit}
    mpath = run_dir / "manifest.json"
    prev = json.loads(mpath.read_text(encoding="utf-8")) if mpath.exists() else {}
    if prev and prev.get("params") != params:
        raise ReplayError(f"run {run_dir.name} was started with {prev.get('params')}, not {params}")
    if prev.get("status") == "complete":
        return prev
    started_at = prev.get("started_at") or utc_now()
    units_before = prev.get("units_used_from_headers", 0)
    if prev:
        prev["requests_before"] = prev.get("requests", 0)
        prev["resumed_count"] = prev.get("resumed_count", 0) + 1
        _write_json(mpath, prev)

    pages = [m for m in stored_pages(run_dir) if m["status"] == 200]
    n = len(stored_pages(run_dir))
    cursor = pages[-1]["page"]["nextCursor"] if pages else None
    if pages and not pages[-1]["page"]["truncated"]:
        _write_json(mpath, _manifest(run_dir, params, started_at, "complete", None, units_before))
        return json.loads(mpath.read_text(encoding="utf-8"))
    if pages and not cursor:
        raise ReplayError("last stored page has no nextCursor but is truncated; cannot resume")

    fetched = 0
    while True:
        if max_pages is not None and fetched >= max_pages:
            status = "partial"
            break
        r = client.changes(since=since, cursor=cursor, territory=territory, limit=limit)
        n += 1
        fetched += 1
        body = r.data if isinstance(r.data, dict) else {}
        meta = r.meta() | {"page_no": n, "cursor_sent": cursor, "page": {
            k: body.get(k) for k in ("since", "nextSince", "nextCursor", "total", "returned",
                                      "offset", "truncated", "territory")}}
        (run_dir / f"page_{n:05d}.json").write_bytes(r.raw)
        _write_json(run_dir / f"page_{n:05d}.meta.json", meta)
        if r.status != 200:
            _write_json(mpath, _manifest(run_dir, params, started_at, "failed", client, units_before))
            raise ReplayError(f"page {n}: HTTP {r.status}: {str(r.data)[:300]}")
        nxt = body.get("nextCursor")
        if not body.get("truncated"):
            status = "complete"
            break
        if not nxt:
            # contract: null on an empty page, keep the cursor already held
            status = "partial"
            break
        cursor = nxt
        _write_json(mpath, _manifest(run_dir, params, started_at, "running", client, units_before))

    _write_json(mpath, _manifest(run_dir, params, started_at, status, client, units_before))
    return json.loads(mpath.read_text(encoding="utf-8"))


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--since", default="2000-01-01T00:00:00Z")
    ap.add_argument("--territory", default="EU")
    ap.add_argument("--limit", type=int, default=PAGE_LIMIT)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--resume", type=Path, help="run directory to resume")
    ap.add_argument("--max-pages", type=int)
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)

    from dotenv import load_dotenv
    load_dotenv(a.env)
    if a.resume:
        run_dir = a.resume
        m = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
        a.since, a.territory, a.limit = m["params"]["since"], m["params"]["territory"], m["params"]["limit"]
    else:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        run_dir = a.out / f"{stamp}_{(a.territory or 'ALL').lower()}"
    m = run(RelayXClient(), run_dir, a.since, a.territory, a.limit, a.max_pages)
    print(json.dumps({k: m[k] for k in ("run_id", "status", "pages", "rows", "first_page_total",
                                         "requests", "units_used_from_headers")}, indent=1))
    print("run dir:", run_dir)
    return 0 if m["status"] == "complete" else 1


if __name__ == "__main__":
    sys.exit(main())

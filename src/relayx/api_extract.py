"""
Generic extractor for every endpoint except /changes (ADR-001 Amendment 1).

Layout of one run (append-only):
    <out>/<run_id>/call_00001.json        raw response bytes
    <out>/<run_id>/call_00001.meta.json   endpoint, path, params, body sent, source_ref,
                                          timestamp, status, hashes, rate headers
    <out>/<run_id>/specs.json             planned calls (keyed runs), written once
    <out>/<run_id>/manifest.json          run id, feed, params, times, counts, status

Two kinds of run:
- list runs: one paginated corpus list (/texts, /coverage, /allergens), offset paging
  until the rows returned add up to `total`;
- keyed runs: a fixed list of calls (per entry or per substance). Resumable: calls already
  stored are skipped. A lookup:batch answer with `truncated: true` gets its unevaluated
  items appended as a new call.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

from .client import ApiResult, RelayXClient, utc_now

LIST_KEYS = {"/texts": "texts", "/coverage": "coverage", "/allergens": "allergens"}


def _write_json(path: Path, obj) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(obj, indent=1, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, path)


class RunWriter:
    def __init__(self, run_dir: Path, feed: str, params: dict, client: RelayXClient):
        self.run_dir, self.feed, self.params, self.client = run_dir, feed, params, client
        run_dir.mkdir(parents=True, exist_ok=True)
        mp = run_dir / "manifest.json"
        self.prev = json.loads(mp.read_text(encoding="utf-8")) if mp.exists() else {}
        self.started_at = self.prev.get("started_at") or utc_now()
        self.metas = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(run_dir.glob("call_*.meta.json"))]

    @property
    def calls(self) -> int:
        return len(self.metas)

    def store(self, spec: dict, r: ApiResult) -> dict:
        n = self.calls + 1
        meta = r.meta() | {"call_no": n, "endpoint": spec["endpoint"], "path": spec["path"],
                           "source_ref": spec.get("source_ref"), "units_requested": spec.get("units", 1)}
        (self.run_dir / f"call_{n:05d}.json").write_bytes(r.raw)
        _write_json(self.run_dir / f"call_{n:05d}.meta.json", meta)
        self.metas.append(meta)
        self.manifest("running")
        return meta

    def manifest(self, status: str) -> dict:
        m = {
            "run_id": self.run_dir.name, "feed": self.feed, "params": self.params,
            "started_at": self.started_at, "updated_at": utc_now(),
            "finished_at": utc_now() if status in ("complete", "failed") else None,
            "status": status, "calls": self.calls,
            "by_status": dict(Counter(str(m["status"]) for m in self.metas)),
            "requests": self.prev.get("requests", 0) + self.client.requests_sent,
            "units_requested": sum(m.get("units_requested", 1) for m in self.metas),
            "units_used_from_headers": self.prev.get("units_used_from_headers", 0)
                                       + self.client.quota.units_from_headers,
        }
        _write_json(self.run_dir / "manifest.json", m)
        return m


def _call(client: RelayXClient, spec: dict) -> ApiResult:
    return client.request(spec.get("method", "GET"), spec["path"], params=spec.get("params"),
                          json_body=spec.get("body"), units=spec.get("units", 1))


def run_list(client: RelayXClient, run_dir: Path, endpoint: str, params: dict, limit: int = 200) -> dict:
    """Fetch one paginated list completely (offset paging; these routes have no cursor)."""
    w = RunWriter(run_dir, endpoint.strip("/"), params | {"limit": limit}, client)
    if w.prev.get("status") == "complete":
        return w.prev
    key = LIST_KEYS[endpoint]
    offset = sum(len((json.loads((run_dir / f"call_{m['call_no']:05d}.json").read_bytes()) or {}).get(key) or [])
                 for m in w.metas if m["status"] == 200)
    while True:
        spec = {"endpoint": endpoint, "path": endpoint, "params": params | {"limit": limit, "offset": offset},
                "source_ref": {"list": endpoint, "offset": offset}}
        r = _call(client, spec)
        w.store(spec, r)
        if r.status != 200 or not isinstance(r.data, dict):
            return w.manifest("failed" if r.status >= 500 or r.status == 429 else "complete")
        rows = r.data.get(key) or []
        offset += len(rows)
        total = r.data.get("total")
        if not rows or (isinstance(total, int) and offset >= total):
            return w.manifest("complete")


def run_keyed(client: RelayXClient, run_dir: Path, feed: str, specs: list[dict], params: dict | None = None) -> dict:
    """Execute a fixed list of calls; resumable; re-queues truncated batch items."""
    sp = run_dir / "specs.json"
    run_dir.mkdir(parents=True, exist_ok=True)
    if sp.exists():
        specs = json.loads(sp.read_text(encoding="utf-8"))
    else:
        _write_json(sp, specs)
    w = RunWriter(run_dir, feed, params or {}, client)
    if w.prev.get("status") == "complete":
        return w.prev
    queue = list(specs)
    # Rebuild the queue position: stored calls correspond to queue items in order,
    # plus re-queued batch remainders appended along the way.
    done = 0
    for meta in w.metas:
        spec = queue[done]
        done += 1
        _requeue(queue, spec, meta.get("status"), _load_body(run_dir, meta))
    i = done
    while i < len(queue):
        spec = queue[i]
        r = _call(client, spec)
        w.store(spec, r)
        _requeue(queue, spec, r.status, r.data)
        i += 1
    _write_json(sp, queue)
    return w.manifest("complete")


class ResumeError(RuntimeError):
    pass


def _read_manifest(run_dir: Path) -> dict:
    mp = run_dir / "manifest.json"
    if not mp.exists():
        raise ResumeError(f"no manifest.json in {run_dir}")
    return json.loads(mp.read_text(encoding="utf-8"))


def resume_list(client: RelayXClient, run_dir: Path) -> dict:
    """Continue a list run in its own directory, with the parameters it was started with."""
    m = _read_manifest(run_dir)
    endpoint = "/" + m["feed"]
    if endpoint not in LIST_KEYS:
        raise ResumeError(f"{run_dir} is not a list run (feed {m['feed']!r})")
    params = {k: v for k, v in m["params"].items() if k != "limit"}
    return run_list(client, run_dir, endpoint, params, m["params"].get("limit", 200))


def resume_keyed(client: RelayXClient, run_dir: Path, feed: str | None = None) -> dict:
    """Continue a keyed run from its stored specs.json; calls already stored are skipped.
    `feed`, if given, must match the run's feed (guards against resuming the wrong run)."""
    m = _read_manifest(run_dir)
    if not (run_dir / "specs.json").exists():
        raise ResumeError(f"no specs.json in {run_dir}; not a keyed run")
    if feed is not None and m["feed"] != feed:
        raise ResumeError(f"{run_dir} is a {m['feed']!r} run, not {feed!r}")
    return run_keyed(client, run_dir, m["feed"], [], m["params"])


def run_lists(territory: str = "EU", out: Path = Path("data/raw/api"), limit: int = 200) -> list[dict]:
    """One run per corpus list (/texts, /coverage, /allergens) for a territory."""
    from datetime import datetime, timezone
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    client = RelayXClient()
    out_m = []
    for endpoint in LIST_KEYS:
        rd = out / f"{stamp}_{endpoint.strip('/')}_{territory.lower()}"
        out_m.append(run_list(client, rd, endpoint, {"territory": territory}, limit) | {"run_dir": str(rd)})
    return out_m


def main(argv: list[str] | None = None) -> int:
    import argparse
    import sys
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["lists"])
    ap.add_argument("--territory", default="EU")
    ap.add_argument("--resume", type=Path, nargs="+", metavar="RUN_DIR",
                    help="continue these list runs in their own directories instead of starting new ones")
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    if a.resume:
        client = RelayXClient()
        results = [resume_list(client, d) | {"run_dir": str(d)} for d in a.resume]
    else:
        results = run_lists(a.territory)
    for m in results:
        print(json.dumps({k: m[k] for k in ("run_id", "status", "calls", "by_status", "units_requested", "run_dir")}))
    return 0 if all(m["status"] == "complete" for m in results) else 1


def _load_body(run_dir: Path, meta: dict):
    try:
        return json.loads((run_dir / f"call_{meta['call_no']:05d}.json").read_bytes())
    except ValueError:
        return None


def _requeue(queue: list[dict], spec: dict, status, body) -> None:
    if spec.get("method") != "POST" or status != 200 or not isinstance(body, dict) or not body.get("truncated"):
        return
    items = spec["body"]["items"]
    seen = {res["index"] for res in body.get("results") or []}
    rest = [i for i in range(len(items)) if i not in seen]
    if not rest:
        return
    refs = spec.get("source_ref") or [None] * len(items)
    queue.append(spec | {"body": spec["body"] | {"items": [items[i] for i in rest]},
                         "source_ref": [refs[i] for i in rest], "units": len(rest),
                         "requeued_from": spec.get("path")})
if __name__ == "__main__":
    import sys
    sys.exit(main())

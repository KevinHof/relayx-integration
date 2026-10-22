"""
Load stored extraction runs into the raw layer (ADR-001). Files stay the byte-exact
source; this only inserts, never updates.

- /changes runs (page_*.json + page_*.meta.json + manifest.json)
      -> relayx_ops.extract_run, relayx_raw.changes_page, relayx_raw.entry_version
- other endpoint runs (call_*.json + call_*.meta.json + manifest.json, see api_extract)
      -> relayx_ops.extract_run, relayx_raw.api_response
  Covalo lookup runs (relayx.covalo_lookup) also carry a per-item ledger in the manifest
  (stored with it in extract_run.manifest); it is reconciled against the bodies first and
  any mismatch stops the load.

One transaction per run; a run_id that is already loaded is refused. Every raw file is
checked against its stored sha256 before insert. After the load, `check_*` recomputes
counts and every payload hash from what the database returns.

Usage:
    python -m relayx.load_raw <run_dir> [<run_dir> ...]
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from psycopg.types.json import Jsonb

from .covalo_lookup import LedgerCheck, LedgerMismatch
from .db import connect
from .hashing import canonical_sha256, sha256_bytes


class LoadError(RuntimeError):
    pass


def _rel(path: Path) -> str:
    try:
        return path.resolve().relative_to(Path.cwd().resolve()).as_posix()
    except ValueError:
        return path.resolve().as_posix()


def _read_verified(meta: dict, path: Path) -> bytes:
    raw = path.read_bytes()
    if sha256_bytes(raw) != meta["sha256_raw"]:
        raise LoadError(f"sha256 mismatch for {path}")
    return raw


def _json_or_none(raw: bytes):
    try:
        return json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        return None


def _insert_run(cur, run_dir: Path, manifest: dict, feed: str) -> None:
    cur.execute("SELECT 1 FROM relayx_ops.extract_run WHERE run_id = %s", (manifest["run_id"],))
    if cur.fetchone():
        raise LoadError(f"run {manifest['run_id']} is already loaded")
    cur.execute(
        """INSERT INTO relayx_ops.extract_run
           (run_id, feed, params, started_at, finished_at, status, pages, row_count, requests,
            units_used_from_headers, last_cursor, final_cursor, last_next_since, raw_dir, manifest)
           VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
        (manifest["run_id"], feed, Jsonb(manifest.get("params") or {}), manifest["started_at"],
         manifest.get("finished_at"), manifest["status"], manifest.get("pages", manifest.get("calls")),
         manifest.get("rows"), manifest.get("requests"), manifest.get("units_used_from_headers"),
         manifest.get("last_cursor"), manifest.get("final_cursor"), manifest.get("last_next_since"),
         _rel(run_dir), Jsonb(manifest)))


def load_changes_run(conn, run_dir: Path) -> dict:
    manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
    run_id = manifest["run_id"]
    pages = rows = 0
    with conn.transaction():
        cur = conn.cursor()
        _insert_run(cur, run_dir, manifest, "changes")
        for mp in sorted(run_dir.glob("page_*.meta.json")):
            meta = json.loads(mp.read_text(encoding="utf-8"))
            page_file = run_dir / f"page_{meta['page_no']:05d}.json"
            raw = _read_verified(meta, page_file)
            body = _json_or_none(raw)
            p = meta["page"]
            envelope = {k: v for k, v in body.items() if k != "changes"} if isinstance(body, dict) else body
            cur.execute(
                """INSERT INTO relayx_raw.changes_page
                   (run_id, page_no, requested_at, http_status, request_params, cursor_sent, next_cursor,
                    next_since, page_total, page_returned, truncated, response_bytes, response_sha256,
                    rate_headers, envelope, raw_file)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (run_id, meta["page_no"], meta["requested_at"], meta["status"], Jsonb(meta["params"]),
                 meta.get("cursor_sent"), p.get("nextCursor"), p.get("nextSince"), p.get("total"),
                 p.get("returned"), p.get("truncated"), meta["bytes"], meta["sha256_raw"],
                 Jsonb(meta.get("rate") or {}), Jsonb(envelope) if envelope is not None else None,
                 _rel(page_file)))
            pages += 1
            if meta["status"] != 200 or not isinstance(body, dict):
                continue
            with cur.copy("""COPY relayx_raw.entry_version
                             (run_id, page_no, row_no, logical_entry_id, known_since, change_kind,
                              payload, payload_sha256) FROM STDIN""") as cp:
                for i, el in enumerate(body.get("changes") or [], start=1):
                    cp.write_row((run_id, meta["page_no"], i, el.get("logicalEntryId"), el.get("knownSince"),
                                  el.get("changeKind"), json.dumps(el, ensure_ascii=False),
                                  canonical_sha256(el)))
                    rows += 1
    return {"run_id": run_id, "pages": pages, "rows": rows}


def load_api_run(conn, run_dir: Path) -> dict:
    manifest = json.loads((run_dir / "manifest.json").read_text(encoding="utf-8"))
    run_id = manifest["run_id"]
    calls = 0
    # Covalo lookup runs carry a per-item ledger in the manifest: it must match the stored
    # bodies exactly (count per call, index, ok, error, ingredientStatus) or nothing is loaded.
    ledger = LedgerCheck(manifest) if "ledger" in manifest else None
    with conn.transaction():
        cur = conn.cursor()
        _insert_run(cur, run_dir, manifest, manifest["feed"])
        for mp in sorted(run_dir.glob("call_*.meta.json")):
            meta = json.loads(mp.read_text(encoding="utf-8"))
            call_file = run_dir / f"call_{meta['call_no']:05d}.json"
            raw = _read_verified(meta, call_file)
            body = _json_or_none(raw)
            if ledger is not None:
                try:
                    ledger.add(meta, body)
                except LedgerMismatch as exc:
                    raise LoadError(str(exc)) from exc
            cur.execute(
                """INSERT INTO relayx_raw.api_response
                   (run_id, call_no, endpoint, method, request_params, request_body, source_ref,
                    requested_at, http_status, response_bytes, response_sha256, body_sha256,
                    rate_headers, body, raw_file)
                   VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                (run_id, meta["call_no"], meta["endpoint"], meta["method"], Jsonb(meta["params"]),
                 Jsonb(meta["body_sent"]) if meta.get("body_sent") is not None else None,
                 Jsonb(meta.get("source_ref")) if meta.get("source_ref") is not None else None,
                 meta["requested_at"], meta["status"], meta["bytes"], meta["sha256_raw"],
                 canonical_sha256(body) if body is not None else None,
                 Jsonb(meta.get("rate") or {}), Jsonb(body) if body is not None else None,
                 _rel(call_file)))
            calls += 1
        info = {"run_id": run_id, "calls": calls}
        if ledger is not None:
            try:
                info["ledger_check"] = ledger.finish()
            except LedgerMismatch as exc:
                raise LoadError(str(exc)) from exc
    return info


def check_changes_run(conn, run_id: str) -> dict:
    cur = conn.cursor()
    cur.execute("SELECT row_count, pages, manifest->>'first_page_total' FROM relayx_ops.extract_run WHERE run_id=%s",
                (run_id,))
    manifest_rows, manifest_pages, first_total = cur.fetchone()
    cur.execute("""SELECT count(*), coalesce(sum(page_returned),0), count(*) FILTER (WHERE http_status <> 200)
                   FROM relayx_raw.changes_page WHERE run_id=%s""", (run_id,))
    db_pages, sum_returned, non200 = cur.fetchone()
    cur.execute("""SELECT count(*), count(DISTINCT logical_entry_id),
                          count(*) - count(DISTINCT (logical_entry_id, known_since)),
                          count(*) FILTER (WHERE known_since IS NULL)
                   FROM relayx_raw.entry_version WHERE run_id=%s""", (run_id,))
    db_rows, distinct_ids, dup_pairs, null_ks = cur.fetchone()
    mismatched = 0
    cur.execute("SELECT payload, payload_sha256 FROM relayx_raw.entry_version WHERE run_id=%s", (run_id,))
    for payload, h in cur:
        if canonical_sha256(payload) != h:
            mismatched += 1
    return {"manifest_rows": manifest_rows, "first_page_total": int(first_total) if first_total else None,
            "manifest_pages": manifest_pages, "db_pages": db_pages, "non_200_pages": non200,
            "sum_page_returned": sum_returned, "db_rows": db_rows, "distinct_logical_entry_id": distinct_ids,
            "duplicate_id_known_since": dup_pairs, "null_known_since": null_ks,
            "payload_hash_mismatch_after_roundtrip": mismatched,
            "ok": (manifest_rows == db_rows == sum_returned and db_pages == manifest_pages
                   and dup_pairs == 0 and mismatched == 0)}


def check_api_run(conn, run_id: str) -> dict:
    cur = conn.cursor()
    cur.execute("SELECT (manifest->>'calls')::int FROM relayx_ops.extract_run WHERE run_id=%s", (run_id,))
    manifest_calls = cur.fetchone()[0]
    cur.execute("""SELECT endpoint, http_status, count(*) FROM relayx_raw.api_response WHERE run_id=%s
                   GROUP BY 1,2 ORDER BY 1,2""", (run_id,))
    by_status = [list(r) for r in cur.fetchall()]
    mismatched = 0
    cur.execute("SELECT body, body_sha256 FROM relayx_raw.api_response WHERE run_id=%s AND body IS NOT NULL",
                (run_id,))
    for body, h in cur:
        if canonical_sha256(body) != h:
            mismatched += 1
    db_calls = sum(r[2] for r in by_status)
    return {"manifest_calls": manifest_calls, "db_calls": db_calls, "by_endpoint_status": by_status,
            "body_hash_mismatch_after_roundtrip": mismatched,
            "ok": manifest_calls == db_calls and mismatched == 0}


def load(run_dir: Path) -> dict:
    with connect() as conn:
        if any(run_dir.glob("page_*.meta.json")):
            info = load_changes_run(conn, run_dir)
            info["checks"] = check_changes_run(conn, info["run_id"])
        else:
            info = load_api_run(conn, run_dir)
            info["checks"] = check_api_run(conn, info["run_id"])
    return info


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dirs", type=Path, nargs="+")
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    ok = True
    for d in a.run_dirs:
        info = load(d)
        print(json.dumps(info, indent=1, default=str))
        ok &= info["checks"]["ok"]
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

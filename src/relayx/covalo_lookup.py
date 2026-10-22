"""
F2 lookup run with Covalo identifiers (docs/plans/2026-10-20-f2-covalo-lookup.md).
Exposed through the per-substance command: `python -m relayx.substance_pilot lookup|preflight`.

lookup:batch only, territory EU, view=full, 25 items per call, limit=100, default sections
and context (as in run 20261019T174653Z_substance_pilot_eu). One item per Covalo value
(data/f2_lookup/<date>/values.csv), never several identifiers in one item.

Quota: units are counted here, one per item sent, never read from RateLimit-Remaining.
Calls are paced so that the units sent in any 60-second span stay within
--rate-per-minute (default 60, at most 300). The RateLimit-* headers are logged after every
batch next to our own count, and a Remaining below the next batch size makes the run wait
for RateLimit-Reset (extra brake only; it never adds sends). Responses the contract says
consume no unit (401, 429, 503) are not counted; a request lost to a network error is.

Run directory data/raw/api/<UTCstamp>_covalo_lookup_eu[_canary<N>]/ (api_extract layout):
    call_00001.json        raw response bytes, written before anything else
    call_00001.meta.json   request (body, its SHA-256 over the exact bytes sent), items sent,
                           status, rate headers, hashes; written second: a call counts as
                           recorded once its meta file exists
    manifest.json          written third, before the next call: status, counts, call_log
                           (items sent per call with the request SHA-256) and the per-item
                           ledger (call_no, index, type, value, ok, error, message,
                           ingredientStatus). The ledger is a reconciliation copy; the stored
                           bodies are the source of truth (relayx.load_raw checks one against
                           the other).
    run.log                one line per batch (status, our units, rate headers) and one
                           progress line per minute

Resume rebuilds the state from the stored calls and restarts at the first unrecorded item;
nothing recorded is sent again. A truncated batch is followed by a resend of exactly the
items after the last returned index. No database access.
"""
from __future__ import annotations

import ctypes
import json
import os
import re
import shutil
import time
from collections import Counter, deque
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import parse_qsl, urlsplit

import requests

from .client import API_PREFIX, RATE_HEADERS, reset_wait_seconds, resolve_base_url, utc_now
from .hashing import canonical_sha256, sha256_bytes
from .lookup_values import PARAM

FEED = "covalo_lookup"
PATH = "/substances/lookup:batch"
BATCH_ITEMS, BATCH_LIMIT = 25, 100
BODY_FIXED = {"territory": "EU", "view": "full", "limit": BATCH_LIMIT}
MAX_RATE = 300
LOG_HEADERS = ("RateLimit-Limit", "RateLimit-Remaining", "RateLimit-Reset", "RateLimit-Policy")
NO_UNIT_STATUSES = {401, 429, 503}
DATE_KEYS = {"since", "asOf", "as_of"}
ISO_8601 = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2}))?$")
PILOT_RUN = Path("data/raw/api/20261019T174653Z_substance_pilot_eu")
UPPER_BYTES_PER_ITEM = 130 * 1024
ES_CONTINUOUS, ES_SYSTEM_REQUIRED = 0x80000000, 0x00000001


class StopRun(RuntimeError):
    """Ends the run without retry; the reason goes to the manifest."""


# ------------------------------------------------------------------ request checks
def request_bytes(body: dict) -> bytes:
    """The exact bytes sent; reproducible from the stored body_sent (key order kept)."""
    return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def build_body(items: list[dict]) -> dict:
    return {"items": [{v["param"]: v["value"]} for v in items], **BODY_FIXED}


def check_request(url: str, params: dict | None = None, body: dict | None = None) -> None:
    """No query parameter twice (Relay X answers 400 ambiguous_parameter), every date ISO 8601,
    one identifier per batch item, items x limit within 2,500."""
    pairs = parse_qsl(urlsplit(url).query, keep_blank_values=True) + list((params or {}).items())
    names = Counter(k for k, _ in pairs)
    dup = sorted(k for k, n in names.items() if n > 1)
    if dup:
        raise ValueError(f"query parameter sent more than once: {dup}")
    for k, v in pairs:
        if isinstance(v, (list, tuple, dict)):
            raise ValueError(f"query parameter {k} is structured")
        if k in DATE_KEYS and not ISO_8601.match(str(v)):
            raise ValueError(f"{k}={v!r} is not ISO 8601")
    if body is not None:
        for k in DATE_KEYS & set(body):
            if not ISO_8601.match(str(body[k])):
                raise ValueError(f"body {k}={body[k]!r} is not ISO 8601")
        items = body.get("items") or []
        if not 1 <= len(items) <= BATCH_ITEMS:
            raise ValueError(f"{len(items)} items outside 1..{BATCH_ITEMS}")
        if any(len(i) != 1 for i in items):
            raise ValueError("an item carries more than one identifier")
        if len(items) * body.get("limit", 50) > 2500:
            raise ValueError("items x limit above 2,500")


# ------------------------------------------------------------------ keep awake
class KeepAwake:
    """SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) while the run is active,
    reset to ES_CONTINUOUS on exit (also on errors and Ctrl+C). No-op off Windows."""

    def __init__(self, kernel32=None):
        self.k = kernel32 if kernel32 is not None else getattr(getattr(ctypes, "windll", None), "kernel32", None)

    def __enter__(self):
        if self.k is not None:
            self.k.SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED)
        return self

    def __exit__(self, *exc):
        if self.k is not None:
            self.k.SetThreadExecutionState(ES_CONTINUOUS)
        return False


# ------------------------------------------------------------------ per-call ledger
def ledger_entries(meta: dict, body: Any) -> list[dict]:
    """Ledger rows for the items a stored call evaluated (results[] of a 200 answer)."""
    if meta["status"] != 200 or not isinstance(body, dict):
        return []
    sent = meta["source_ref"]
    out = []
    for r in body.get("results") or []:
        ref = sent[r["index"]]
        out.append({"item": ref["item"], "type": ref["type"], "value": ref["value"], "call_no": meta["call_no"],
                    "index": r["index"], "ok": r.get("ok"), "error": r.get("error"), "message": r.get("message"),
                    "ingredient_status": (r.get("ingredientStatus") or {}).get("status")})
    return out


def check_results(sent: int, body: dict) -> tuple[int, list[int]]:
    """(last returned index, unevaluated indices). Results must be the indices 0..last without
    gaps or repeats; anything else stops the run (unevaluated items must never be guessed)."""
    idx = [r.get("index") for r in body.get("results") or []]
    last = len(idx) - 1
    if idx != list(range(len(idx))) or len(idx) > sent:
        raise StopRun(f"result indices {idx} do not form 0..n-1 for {sent} items sent")
    rest = list(range(last + 1, sent))
    if rest and not body.get("truncated"):
        raise StopRun(f"{len(rest)} items unanswered without truncated: true")
    return last, rest


def _write_atomic(path: Path, data: bytes) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_bytes(data)
    os.replace(tmp, path)


def _json(obj) -> bytes:
    return json.dumps(obj, indent=1, ensure_ascii=False).encode("utf-8")


# ------------------------------------------------------------------ run
@dataclass
class Config:
    rate_per_minute: int = 60
    max_units: int = 24000
    max_items: int | None = None
    max_retries: int = 3
    max_consecutive_failures: int = 10
    timeout: int = 180

    def validate(self) -> None:
        if not 1 <= self.rate_per_minute <= MAX_RATE:
            raise ValueError(f"--rate-per-minute must be 1..{MAX_RATE}")
        if self.rate_per_minute < BATCH_ITEMS:
            raise ValueError(f"--rate-per-minute below the batch size {BATCH_ITEMS}")
        if self.max_units < 1 or (self.max_items is not None and self.max_items < 1):
            raise ValueError("--max-units and --max-items must be positive")


class LookupRun:
    def __init__(self, run_dir: Path, values: list[dict], values_file: Path, cfg: Config,
                 session=None, api_key: str | None = None, base_url: str | None = None,
                 sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
                 now: Callable[[], str] = utc_now, echo: Callable[[str], None] = print):
        cfg.validate()
        self.run_dir, self.cfg = run_dir, cfg
        self.values_file = values_file
        self.items = values[:cfg.max_items] if cfg.max_items else list(values)
        self.session = session or requests.Session()
        self._key = api_key if api_key is not None else os.environ.get("RELAYX_API_KEY")
        self.url = resolve_base_url(base_url or os.environ.get("RELAYX_BASE_URL")) + PATH
        self._sleep, self.clock, self.now, self.echo = sleep, clock, now, echo
        self.sent_window: deque[tuple[float, int]] = deque()
        self.last_rate: dict = {}
        self.consecutive_failures = 0
        self.session_started = clock()
        self.session_items_start = 0
        self.last_progress = clock()

    # ---------------------------------------------------------------- state
    def _load_state(self, prev: dict) -> None:
        self.metas = [json.loads(p.read_text(encoding="utf-8")) for p in sorted(self.run_dir.glob("call_*.meta.json"))]
        self.ledger: list[dict] = []
        self.call_log: list[dict] = []
        self.truncations: list[dict] = []
        self.resend: list[int] = []          # positions in self.items to send next, exactly
        pos = {v["seq"]: i for i, v in enumerate(self.items)}
        for m in self.metas:
            body = json.loads((self.run_dir / f"call_{m['call_no']:05d}.json").read_bytes() or b"null") \
                if m["status"] == 200 else None
            self._account(m, body, pos)
        self.units_used = sum(m["units_counted"] for m in self.metas) + prev.get("units_network_errors", 0)
        self.units_network_errors = prev.get("units_network_errors", 0)
        self.network_errors = prev.get("network_errors", 0)
        self.requests_prev = prev.get("requests", 0)
        self.requests = 0
        stems = [int(p.name[5:10]) for p in self.run_dir.glob("call_*.json") if p.name[5:10].isdigit()]
        self.next_call_no = max(stems, default=0) + 1
        recorded = {m["call_no"] for m in self.metas}
        self.orphans = sorted(n for n in stems if n not in recorded)

    def _account(self, meta: dict, body, pos: dict) -> None:
        """Fold one stored call into ledger, call log and the resend list."""
        self.call_log.append({"call_no": meta["call_no"], "status": meta["status"],
                              "request_sha256": meta["request_sha256"],
                              "items": [[i, r["type"], r["value"]] for i, r in enumerate(meta["source_ref"])]})
        self.ledger.extend(ledger_entries(meta, body))
        if meta["status"] == 200 and isinstance(body, dict):
            # Only an answered batch changes what is sent next; after a 429 or 5xx the same
            # items (a pending resend included) go out again.
            last, rest = check_results(len(meta["source_ref"]), body)
            if body.get("truncated"):
                self.truncations.append({"call_no": meta["call_no"], "reason": body.get("truncatedReason"),
                                         "sent": len(meta["source_ref"]), "returned": last + 1})
            self.resend = [pos[meta["source_ref"][i]["item"]] for i in rest]

    @property
    def recorded(self) -> set[int]:
        return {e["item"] for e in self.ledger}

    def next_batch(self) -> list[int]:
        done = self.recorded
        if self.resend:
            return [i for i in self.resend if self.items[i]["seq"] not in done]
        return [i for i, v in enumerate(self.items) if v["seq"] not in done][:BATCH_ITEMS]

    def manifest(self, status: str, stop_reason: str | None = None) -> dict:
        failed = [e for e in self.ledger if e["ok"] is False]
        m = {"run_id": self.run_dir.name, "feed": FEED,
             "params": {"values_file": self.values_file.as_posix(), "values_sha256": self.values_sha256,
                        "max_items": self.cfg.max_items, "items_selected": len(self.items),
                        "path": API_PREFIX + PATH, **BODY_FIXED, "batch_items": BATCH_ITEMS,
                        "rate_per_minute": self.cfg.rate_per_minute, "max_units": self.cfg.max_units},
             "started_at": self.started_at, "updated_at": self.now(),
             "finished_at": self.now() if status in ("complete", "partial", "failed") else None,
             "status": status, "stop_reason": stop_reason,
             "calls": len(self.metas), "requests": self.requests_prev + self.requests,
             "by_status": dict(Counter(str(m["status"]) for m in self.metas)),
             "units_used": self.units_used, "units_network_errors": self.units_network_errors,
             "network_errors": self.network_errors, "units_used_from_headers": None,
             "items_recorded": len(self.ledger), "items_failed": len(failed),
             "ingredient_status": dict(Counter(str(e["ingredient_status"]) for e in self.ledger if e["ok"])),
             "truncations": self.truncations, "orphan_calls": self.orphans,
             "failed_items": [{k: e[k] for k in ("item", "type", "value", "call_no", "index", "error", "message")}
                              for e in failed],
             "call_log": self.call_log, "ledger": self.ledger}
        _write_atomic(self.run_dir / "manifest.json", _json(m))
        return m

    # ---------------------------------------------------------------- logging, waiting
    def log(self, msg: str, console: bool = False) -> None:
        line = f"{self.now()} {msg}"
        with (self.run_dir / "run.log").open("a", encoding="utf-8") as f:
            f.write(line + "\n")
        if console:
            self.echo(line)

    def progress(self, force: bool = False) -> None:
        t = self.clock()
        if not force and t - self.last_progress < 60:
            return
        self.last_progress = t
        done, total = len(self.ledger), len(self.items)
        session_done = done - self.session_items_start
        elapsed = t - self.session_started
        per_min = session_done / elapsed * 60 if elapsed >= 60 and session_done else self.cfg.rate_per_minute
        eta = (total - done) / per_min if per_min else float("inf")
        errors = sum(e["ok"] is False for e in self.ledger) + sum(m["status"] != 200 for m in self.metas) \
            + self.network_errors
        self.log(f"progress items {done}/{total} units {self.units_used}/{self.cfg.max_units} errors {errors} "
                 f"truncations {len(self.truncations)} eta {eta:.0f} min", console=True)

    def sleep(self, seconds: float, why: str) -> None:
        if seconds <= 0:
            return
        self.log(f"wait {seconds:.1f}s ({why})", console=seconds >= 30)
        end = self.clock() + seconds
        while (left := end - self.clock()) > 0:
            self._sleep(min(left, 5.0))
            self.progress()

    def pace(self, n: int) -> None:
        """Units sent in any 60-second span stay within rate_per_minute."""
        while True:
            t = self.clock()
            while self.sent_window and t - self.sent_window[0][0] >= 60:
                self.sent_window.popleft()
            used = sum(u for _, u in self.sent_window)
            if used + n <= self.cfg.rate_per_minute:
                break
            self.sleep(60 - (t - self.sent_window[0][0]) + 0.05, f"pacing {used}+{n} > {self.cfg.rate_per_minute}/min")
        rem = self.last_rate.get("RateLimit-Remaining")
        if rem is not None and rem.isdigit() and int(rem) < n:
            w = reset_wait_seconds(self.last_rate.get("RateLimit-Reset"))
            self.sleep((w if w is not None else 60) + 2, f"RateLimit-Remaining {rem} < {n}")
            self.last_rate = {}

    def wait_quota(self, rate: dict, why: str) -> None:
        """c: Retry-After + 2 when present, else until RateLimit-Reset + 2."""
        w = reset_wait_seconds(rate.get("Retry-After"))
        if w is None:
            w = reset_wait_seconds(rate.get("RateLimit-Reset"))
        self.sleep((w if w is not None else 60) + 2, why)

    # ---------------------------------------------------------------- one call
    def send(self, positions: list[int]) -> tuple[dict, Any]:
        items = [self.items[i] for i in positions]
        body = build_body(items)
        check_request(self.url, None, body)
        raw_body = request_bytes(body)
        n = len(items)
        if self.units_used + n > self.cfg.max_units:
            raise StopRun(f"unit cap: {self.units_used} used, next batch {n}, cap {self.cfg.max_units}")
        self.pace(n)
        requested_at = self.now()
        t0 = self.clock()
        self.sent_window.append((t0, n))
        self.requests += 1
        try:
            resp = self.session.post(self.url, data=raw_body, timeout=self.cfg.timeout,
                                     headers={"Content-Type": "application/json", "Accept": "application/json",
                                              "User-Agent": "covalo-relayx-integration/0.1", "X-Api-Key": self._key})
        except requests.RequestException:
            self.units_used += n
            self.units_network_errors += n
            self.network_errors += 1
            raise
        raw = resp.content or b""
        rate = {h: resp.headers.get(h) for h in RATE_HEADERS if resp.headers.get(h) is not None}
        counted = 0 if resp.status_code in NO_UNIT_STATUSES else n
        if counted == 0:
            self.sent_window[-1] = (t0, 0)
        self.units_used += counted
        try:
            data = json.loads(raw)
        except ValueError:
            data = None
        call_no = self.next_call_no
        self.next_call_no += 1
        meta = {"method": "POST", "path": API_PREFIX + PATH, "params": {}, "body_sent": body,
                "request_sha256": sha256_bytes(raw_body), "status": resp.status_code,
                "elapsed_s": round(self.clock() - t0, 3), "bytes": len(raw), "sha256_raw": sha256_bytes(raw),
                "sha256_canonical": canonical_sha256(data) if data is not None else None, "rate": rate,
                "content_type": resp.headers.get("Content-Type"), "requested_at": requested_at,
                "call_no": call_no, "endpoint": PATH,
                "source_ref": [{"item": v["seq"], "type": v["id_type"], "value": v["value"], "products": v["products"]}
                               for v in items],
                "units_requested": n, "units_counted": counted,
                "truncated": data.get("truncated") if isinstance(data, dict) else None,
                "truncated_reason": data.get("truncatedReason") if isinstance(data, dict) else None}
        _write_atomic(self.run_dir / f"call_{call_no:05d}.json", raw)
        _write_atomic(self.run_dir / f"call_{call_no:05d}.meta.json", _json(meta))
        self.metas.append(meta)
        pos = {self.items[i]["seq"]: i for i in positions}
        self._account(meta, data, pos)
        self.manifest("running")
        self.last_rate = rate
        window = sum(u for _, u in self.sent_window)
        self.log(f"call {call_no} items {n} status {resp.status_code} bytes {len(raw)} elapsed {meta['elapsed_s']}s "
                 f"our_units {self.units_used} our_units_60s {window} "
                 + " ".join(f"{h}={rate.get(h)}" for h in LOG_HEADERS))
        return meta, data

    def batch(self, positions: list[int]) -> str:
        """One batch with its retries: 'ok', 'truncated' or 'failed'. StopRun ends the run."""
        attempt = 0
        while True:
            attempt += 1
            try:
                meta, data = self.send(positions)
            except requests.RequestException as exc:
                self.log(f"network error {type(exc).__name__} (attempt {attempt})", console=True)
                if attempt > self.cfg.max_retries:
                    return "failed"
                self.sleep(5 * 2 ** (attempt - 1), "network error backoff")
                continue
            s = meta["status"]
            if s == 200:
                if not isinstance(data, dict):
                    raise StopRun(f"call {meta['call_no']}: 200 without a JSON object")
                for e in ledger_entries(meta, data):
                    if e["ok"] is False:
                        self.log(f"item {e['item']} {e['type']}={e['value']!r} ok=false {e['error']}: {e['message']}")
                if data.get("truncated"):
                    self.log(f"call {meta['call_no']} truncated ({data.get('truncatedReason')}): "
                             f"{len(self.resend)} items to resend", console=True)
                    if meta["rate"].get("Retry-After") is not None:
                        self.wait_quota(meta["rate"], "truncated, Retry-After")
                    return "truncated"
                return "ok"
            if s == 429:
                self.wait_quota(meta["rate"], "429")
                return "failed"
            if s in (401, 403):
                raise StopRun(f"call {meta['call_no']}: HTTP {s}")
            if s == 400:
                text = (self.run_dir / f"call_{meta['call_no']:05d}.json").read_bytes().decode("utf-8", "replace")
                self.log(f"HTTP 400 body: {text}", console=True)
                raise StopRun(f"call {meta['call_no']}: HTTP 400")
            if s >= 500:
                if attempt > self.cfg.max_retries:
                    return "failed"
                ra = reset_wait_seconds(meta["rate"].get("Retry-After"))
                self.sleep(ra + 2 if ra is not None else 10 * 2 ** (attempt - 1), f"HTTP {s} backoff")
                continue
            raise StopRun(f"call {meta['call_no']}: unexpected HTTP {s}")

    def run(self) -> dict:
        self.run_dir.mkdir(parents=True, exist_ok=True)
        mp = self.run_dir / "manifest.json"
        prev = json.loads(mp.read_text(encoding="utf-8")) if mp.exists() else {}
        self.values_sha256 = sha256_bytes(self.values_file.read_bytes())
        if prev and prev["params"]["values_sha256"] != self.values_sha256:
            raise StopRun("value list changed since the run started")
        self.started_at = prev.get("started_at") or self.now()
        self._load_state(prev)
        self.session_items_start = len(self.ledger)
        if not self._key:
            raise RuntimeError("No API key: set RELAYX_API_KEY in the environment or .env")
        self.log(f"start: {len(self.items)} items selected, {len(self.ledger)} recorded, "
                 f"rate {self.cfg.rate_per_minute}/min, cap {self.cfg.max_units} units, {self.units_used} used",
                 console=True)
        status, reason = "partial", None
        with KeepAwake():
            try:
                while True:
                    pos = self.next_batch()
                    if not pos:
                        status = "complete"
                        break
                    outcome = self.batch(pos)
                    self.consecutive_failures = self.consecutive_failures + 1 if outcome == "failed" else 0
                    if self.consecutive_failures >= self.cfg.max_consecutive_failures:
                        raise StopRun(f"{self.consecutive_failures} consecutive failed batches")
                    self.progress()
            except StopRun as exc:
                reason = str(exc)
                status = "partial" if reason.startswith("unit cap") else "failed"
                self.log(f"stop: {reason}", console=True)
            except KeyboardInterrupt:
                reason = "interrupted (Ctrl+C)"
                self.log("stop: interrupted", console=True)
            except Exception as exc:
                status, reason = "failed", f"error: {exc!r}"
                self.log(f"stop: {reason}", console=True)
                raise
            finally:
                m = self.manifest(status, reason)
                self.progress(force=True)
        for f in m["failed_items"]:
            self.echo(f"ok=false item {f['item']} {f['type']}={f['value']!r}: {f['error']} {f['message']}")
        self.echo(f"{m['status']}: {m['items_recorded']}/{len(self.items)} items, {m['units_used']} units, "
                  f"{m['items_failed']} ok=false, {len(m['truncations'])} truncations, run dir {self.run_dir}")
        return m


# ------------------------------------------------------------------ loader check
class LedgerMismatch(ValueError):
    pass


class LedgerCheck:
    """Reconciles the manifest's call_log and ledger with the stored calls, one call at a
    time (relayx.load_raw). The bodies are the source of truth; any difference raises."""

    def __init__(self, manifest: dict):
        self.log = {c["call_no"]: c for c in manifest.get("call_log") or []}
        self.expected: dict[int, list[dict]] = {}
        for e in manifest.get("ledger") or []:
            self.expected.setdefault(e["call_no"], []).append(e)
        self.n_ledger = len(manifest.get("ledger") or [])
        self.seen: set[int] = set()
        self.items = 0
        self.status = Counter()

    def add(self, meta: dict, body: Any) -> None:
        n = meta["call_no"]
        if sha256_bytes(request_bytes(meta["body_sent"])) != meta["request_sha256"]:
            raise LedgerMismatch(f"call {n}: stored body_sent does not reproduce request_sha256")
        sent = [[i, r["type"], r["value"]] for i, r in enumerate(meta["source_ref"])]
        if [list(x.items()) for x in meta["body_sent"]["items"]] != [[(PARAM[t], v)] for _, t, v in sent]:
            raise LedgerMismatch(f"call {n}: body items differ from source_ref")
        c = self.log.get(n)
        if c is None or c["request_sha256"] != meta["request_sha256"] or c["items"] != sent or c["status"] != meta["status"]:
            raise LedgerMismatch(f"call {n}: call_log differs from the stored call")
        got, exp = ledger_entries(meta, body), self.expected.get(n, [])
        if len(got) != len(exp):
            raise LedgerMismatch(f"call {n}: {len(got)} results in body, {len(exp)} in ledger")
        for g, e in zip(got, exp):
            if g != e:
                diff = {k: (e.get(k), g.get(k)) for k in g if g.get(k) != e.get(k)}
                raise LedgerMismatch(f"call {n} index {g['index']}: ledger vs body {diff}")
        self.seen.add(n)
        self.items += len(got)
        self.status.update(str(g["ingredient_status"]) if g["ok"] else f"ok=false:{g['error']}" for g in got)

    def finish(self) -> dict:
        missing = sorted(set(self.log) - self.seen)
        extra = sorted(set(self.expected) - self.seen)
        if missing or extra or self.items != self.n_ledger:
            raise LedgerMismatch(f"calls in manifest not stored: {missing[:10]}; ledger calls not stored: "
                                 f"{extra[:10]}; ledger rows {self.n_ledger}, body results {self.items}")
        return {"calls_checked": len(self.seen), "items_checked": self.items,
                "ingredient_status": dict(self.status), "ok": True}


# ------------------------------------------------------------------ dry run, preflight
def dry_run(values: list[dict], cfg: Config, pilot_dir: Path = PILOT_RUN, url: str = "https://x" + API_PREFIX + PATH,
            disk: str = "C:\\") -> dict:
    cfg.validate()
    items = values[:cfg.max_items] if cfg.max_items else values
    bodies = [build_body(items[i:i + BATCH_ITEMS]) for i in range(0, len(items), BATCH_ITEMS)]
    for b in bodies:
        check_request(url, None, b)
    calls, units = len(bodies), len(items)
    pb = pr = 0
    elapsed = []
    for mp in sorted(pilot_dir.glob("call_*.meta.json")):
        m = json.loads(mp.read_text(encoding="utf-8"))
        if m["endpoint"].endswith(":batch") and m["status"] == 200:
            body = json.loads((pilot_dir / f"call_{m['call_no']:05d}.json").read_bytes())
            pb += m["bytes"]
            pr += len(body.get("results") or [])
            elapsed.append(m["elapsed_s"])
    per_item = pb / pr if pr else None
    mean_call_s = sum(elapsed) / len(elapsed) if elapsed else None
    du = shutil.disk_usage(disk)

    def minutes(rate):
        quota = units / rate
        latency = calls * mean_call_s / 60 if mean_call_s else 0
        return {"quota_bound_min": round(quota, 1), "latency_bound_min": round(latency, 1),
                "expected_min": round(max(quota, latency), 1)}

    return {"items": units, "calls": calls, "units": units, "units_within_cap": units <= cfg.max_units,
            "items_by_type": dict(Counter(v["id_type"] for v in items)),
            "duration_at_60": minutes(60), "duration_at_300": minutes(300),
            "pilot_run": pilot_dir.name, "pilot_lookup_results": pr, "pilot_bytes_per_item": round(per_item) if per_item else None,
            "pilot_mean_call_s": round(mean_call_s, 2) if mean_call_s else None,
            "disk_estimate_bytes": round(units * per_item) if per_item else None,
            "disk_upper_bound_bytes": units * UPPER_BYTES_PER_ITEM,
            "free_bytes": du.free, "disk": disk}


def preflight(out: Path = Path("data/raw/api"), session=None, api_key: str | None = None,
              base_url: str | None = None) -> dict:
    """One authenticated GET /texts?territory=EU&limit=1 (1 unit). Saves the response and the
    RateLimit-* headers to data/raw/api/<UTCstamp>_preflight/."""
    key = api_key if api_key is not None else os.environ.get("RELAYX_API_KEY")
    if not key:
        raise RuntimeError("No API key: set RELAYX_API_KEY in the environment or .env")
    url = resolve_base_url(base_url or os.environ.get("RELAYX_BASE_URL")) + "/texts"
    params = {"territory": "EU", "limit": 1}
    check_request(url, params)
    session = session or requests.Session()
    requested_at = utc_now()
    resp = session.get(url, params=params, timeout=60, headers={"Accept": "application/json", "X-Api-Key": key,
                                                                "User-Agent": "covalo-relayx-integration/0.1"})
    raw = resp.content or b""
    rate = {h: resp.headers.get(h) for h in LOG_HEADERS + ("Retry-After",)}
    policy = rate.get("RateLimit-Policy") or ""
    ceiling = int(policy.split(";")[0]) if policy.split(";")[0].strip().isdigit() else None
    d = out / (datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "_preflight")
    d.mkdir(parents=True)
    (d / "response.json").write_bytes(raw)
    info = {"requested_at": requested_at, "path": API_PREFIX + "/texts", "params": params, "status": resp.status_code,
            "bytes": len(raw), "sha256_raw": sha256_bytes(raw), "rate": rate, "policy_ceiling": ceiling,
            "policy_is_300": ceiling == 300, "dir": d.as_posix()}
    (d / "preflight.json").write_bytes(_json(info))
    return info

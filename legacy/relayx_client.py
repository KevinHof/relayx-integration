"""
Thin, auditable client for the Relay X Regulatory Data API (v1).

Design goals
------------
1. Reusable: this module is the seed of the ingestion pipeline, so all HTTP,
   quota and persistence logic lives here, not in notebook cells.
2. Auditable: every call is persisted with its request metadata, rate-limit
   state, byte size and two hashes (raw bytes, canonical JSON). The canonical
   hash is independent of key order and is the prototype for change detection.
3. Safe: the API key is read from the environment and never written to disk
   or printed.

Reference: RX-API-EU-01 v1.0 (August 2026). The binding contract is
GET /openapi.json, which may differ from the PDF.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator

import requests

DEFAULT_BASE_URL = "https://app.relay-x.com/api/regulatory/v1"
RATE_HEADERS = ("RateLimit-Limit", "RateLimit-Remaining", "RateLimit-Reset", "Retry-After")
BATCH_MAX = 50        # documented max entries per batch call
BATCH_MAX_FULL = 25   # documented: view=full refused above 25 entries

# Keys under which list endpoints return their rows (auto-detected otherwise)
KNOWN_LIST_KEYS = ("constraints", "changes", "coverage", "texts", "allergens",
                   "listings", "opinions", "versions", "markets", "results", "items")


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def canonical_hash(obj: Any) -> str | None:
    """SHA-256 of canonical JSON (sorted keys, no whitespace). None if not JSON."""
    if obj is None or isinstance(obj, str):
        return None
    payload = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def find_list(data: Any, prefer: str | None = None) -> tuple[str | None, list]:
    """Return (key, rows) for the main list in a response body."""
    if not isinstance(data, dict):
        return (None, data if isinstance(data, list) else [])
    if prefer and isinstance(data.get(prefer), list):
        return prefer, data[prefer]
    for k in KNOWN_LIST_KEYS:
        if isinstance(data.get(k), list):
            return k, data[k]
    for k, v in data.items():
        if isinstance(v, list) and v and isinstance(v[0], dict):
            return k, v
    return None, []


@dataclass
class ApiResult:
    call_id: str
    method: str
    path: str
    params: dict
    body_sent: Any
    auth_style: str
    status: int
    elapsed_s: float
    bytes: int
    sha256_raw: str
    sha256_canonical: str | None
    rate: dict
    content_type: str | None
    requested_at: str
    attempt: int
    raw_file: str | None
    data: Any = None

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def meta(self) -> dict:
        d = asdict(self)
        d.pop("data", None)
        return d

    def rows(self, prefer: str | None = None) -> list:
        return find_list(self.data, prefer)[1]

    def __repr__(self) -> str:
        return (f"<ApiResult {self.method} {self.path} status={self.status} "
                f"bytes={self.bytes} elapsed={self.elapsed_s:.2f}s "
                f"remaining={self.rate.get('RateLimit-Remaining')}>")


class RelayXClient:
    def __init__(
        self,
        api_key: str | None = None,
        base_url: str | None = None,
        raw_dir: str | Path = "raw_responses",
        run_label: str | None = None,
        auth_style: str = "x-api-key",     # or "bearer"
        throttle_floor: int = 2,           # pause when RateLimit-Remaining <= this; -1 disables
        max_retries: int = 3,              # retries on 429
        timeout: int = 120,
        persist: bool = True,
        verbose: bool = True,
    ):
        self._api_key = api_key or os.environ.get("RELAYX_API_KEY")
        self.base_url = (base_url or os.environ.get("RELAYX_BASE_URL") or DEFAULT_BASE_URL).rstrip("/")
        self.auth_style = auth_style
        self.throttle_floor = throttle_floor
        self.max_retries = max_retries
        self.timeout = timeout
        self.persist = persist
        self.verbose = verbose
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        self.run_id = f"{stamp}_{run_label}" if run_label else stamp
        self.run_dir = Path(raw_dir) / self.run_id
        self.session = requests.Session()
        self.session.headers.update({"Accept": "application/json",
                                     "User-Agent": "covalo-relayx-exploration/0.1"})
        self.calls: list[dict] = []
        self.last_rate: dict = {}
        self._seq = 0

    # ------------------------------------------------------------------ utils
    @property
    def has_key(self) -> bool:
        return bool(self._api_key)

    def __repr__(self) -> str:
        return f"<RelayXClient base={self.base_url} run={self.run_id} key={'set' if self.has_key else 'MISSING'}>"

    def _log(self, msg: str) -> None:
        if self.verbose:
            print(msg)

    def _auth_headers(self, auth: bool, auth_style: str | None, key_override: str | None) -> dict:
        if not auth:
            return {}
        key = key_override if key_override is not None else self._api_key
        if not key:
            raise RuntimeError("No API key: set RELAYX_API_KEY in your environment or .env file")
        style = auth_style or self.auth_style
        if style == "bearer":
            return {"Authorization": f"Bearer {key}"}
        return {"X-Api-Key": key}

    def _throttle(self) -> None:
        if self.throttle_floor < 0:
            return
        remaining = self.last_rate.get("RateLimit-Remaining")
        reset = self.last_rate.get("RateLimit-Reset")
        if remaining is not None and reset is not None:
            try:
                if int(remaining) <= self.throttle_floor:
                    wait = int(float(reset)) + 1
                    self._log(f"  throttle: {remaining} left, sleeping {wait}s until reset")
                    time.sleep(wait)
            except ValueError:
                pass

    def _persist(self, result: ApiResult, label: str) -> str | None:
        if not self.persist:
            return None
        self.run_dir.mkdir(parents=True, exist_ok=True)
        fname = f"{self._seq:04d}_{label}.json"
        path = self.run_dir / fname
        with open(path, "w", encoding="utf-8") as f:
            json.dump({"meta": result.meta(), "body": result.data}, f, ensure_ascii=False, indent=1)
        with open(self.run_dir / "calls.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(result.meta(), ensure_ascii=False) + "\n")
        return str(path)

    # ---------------------------------------------------------------- request
    def request(
        self,
        method: str,
        path: str,
        params: dict | None = None,
        json_body: Any = None,
        auth: bool = True,
        auth_style: str | None = None,
        key_override: str | None = None,
        label: str | None = None,
        max_retries: int | None = None,
    ) -> ApiResult:
        params = {k: v for k, v in (params or {}).items() if v is not None}
        url = f"{self.base_url}{path}"
        retries = self.max_retries if max_retries is None else max_retries
        style_used = "none" if not auth else (
            "override:" + (auth_style or self.auth_style) if key_override is not None
            else (auth_style or self.auth_style))
        label = label or path.strip("/").replace("/", "_").replace(":", "_").replace("{", "").replace("}", "") or "root"

        attempt = 0
        while True:
            attempt += 1
            self._throttle()
            self._seq += 1
            requested_at = utc_now()
            t0 = time.perf_counter()
            resp = self.session.request(
                method, url, params=params, json=json_body, timeout=self.timeout,
                headers=self._auth_headers(auth, auth_style, key_override))
            elapsed = time.perf_counter() - t0

            rate = {h: resp.headers.get(h) for h in RATE_HEADERS if resp.headers.get(h) is not None}
            if any(k.startswith("RateLimit") for k in rate):
                self.last_rate = rate
            raw = resp.content or b""
            ctype = resp.headers.get("Content-Type")
            try:
                data = resp.json()
            except ValueError:
                data = resp.text

            result = ApiResult(
                call_id=f"{self.run_id}#{self._seq:04d}", method=method.upper(), path=path,
                params=params, body_sent=json_body, auth_style=style_used, status=resp.status_code,
                elapsed_s=round(elapsed, 3), bytes=len(raw), sha256_raw=hashlib.sha256(raw).hexdigest(),
                sha256_canonical=canonical_hash(data), rate=rate, content_type=ctype,
                requested_at=requested_at, attempt=attempt, raw_file=None, data=data)
            result.raw_file = self._persist(result, label)
            self.calls.append(result.meta())
            self._log(f"  {result!r}")

            if resp.status_code == 429 and attempt <= retries:
                wait = int(float(rate.get("Retry-After") or rate.get("RateLimit-Reset") or 60)) + 1
                self._log(f"  429 received, waiting {wait}s (attempt {attempt}/{retries})")
                time.sleep(wait)
                continue
            return result

    # -------------------------------------------------------------- endpoints
    # Service (no key)
    def health(self) -> ApiResult:
        return self.request("GET", "/health", auth=False)

    def openapi(self, save_to: str | Path | None = None) -> ApiResult:
        r = self.request("GET", "/openapi.json", auth=False, label="openapi")
        if save_to and r.ok and isinstance(r.data, dict):
            Path(save_to).write_text(json.dumps(r.data, indent=1, ensure_ascii=False), encoding="utf-8")
        return r

    # Substances
    @staticmethod
    def _id_params(cas=None, ec=None, inci=None, name=None) -> dict:
        return {"cas": cas, "ec": ec, "inci": inci, "name": name}

    def lookup(self, cas=None, ec=None, inci=None, name=None, territory=None, as_of=None,
               view=None, sections=None, context=None, lang=None, limit=None, offset=None,
               **kw) -> ApiResult:
        params = self._id_params(cas, ec, inci, name) | {
            "territory": territory, "asOf": as_of, "view": view, "sections": sections,
            "context": None if context is None else str(context).lower(),
            "lang": lang, "limit": limit, "offset": offset}
        return self.request("GET", "/substances/lookup", params=params, **kw)

    def lookup_batch(self, items: list[dict], view: str = "standard", sections=None, lang=None,
                     method: str = "POST", extra_body: dict | None = None, **kw) -> list[ApiResult]:
        """Splits into documented chunk sizes. Each item costs one quota unit."""
        size = BATCH_MAX_FULL if view == "full" else BATCH_MAX
        out = []
        for i in range(0, len(items), size):
            body = {"items": items[i:i + size], "view": view}
            if sections:
                body["sections"] = sections
            if lang:
                body["lang"] = lang
            if extra_body:
                body |= extra_body
            out.append(self.request(method, "/substances/lookup:batch", json_body=body,
                                    label=f"lookup_batch_{i // size:03d}", **kw))
        return out

    def market_summary(self, cas=None, ec=None, inci=None, name=None, as_of=None, **kw) -> ApiResult:
        return self.request("GET", "/substances/market-summary",
                            params=self._id_params(cas, ec, inci, name) | {"asOf": as_of}, **kw)

    def impurity_limits(self, cas=None, ec=None, inci=None, name=None, lang=None, **kw) -> ApiResult:
        return self.request("GET", "/substances/impurity-limits",
                            params=self._id_params(cas, ec, inci, name) | {"lang": lang}, **kw)

    def screening(self, cas=None, ec=None, inci=None, **kw) -> ApiResult:
        return self.request("GET", "/substances/screening", params=self._id_params(cas, ec, inci), **kw)

    def opinions(self, cas=None, ec=None, inci=None, **kw) -> ApiResult:
        return self.request("GET", "/substances/opinions", params=self._id_params(cas, ec, inci), **kw)

    # Corpus
    def allergens(self, territory=None, **kw) -> ApiResult:
        return self.request("GET", "/allergens", params={"territory": territory}, **kw)

    def texts(self, territory=None, legislator=None, limit=None, offset=None, **kw) -> ApiResult:
        return self.request("GET", "/texts", params={"territory": territory, "legislator": legislator,
                                                     "limit": limit, "offset": offset}, **kw)

    def coverage(self, territory=None, limit=None, offset=None, **kw) -> ApiResult:
        return self.request("GET", "/coverage", params={"territory": territory, "limit": limit,
                                                        "offset": offset}, **kw)

    # Changes
    def changes(self, since: str, legislator=None, territory=None, limit=None, offset=None, **kw) -> ApiResult:
        return self.request("GET", "/changes", params={"since": since, "legislator": legislator,
                                                       "territory": territory, "limit": limit,
                                                       "offset": offset}, **kw)

    def entry_history(self, logical_entry_id: str, **kw) -> ApiResult:
        return self.request("GET", f"/entries/{logical_entry_id}/history",
                            label=f"entry_history_{logical_entry_id[:8]}", **kw)

    # ------------------------------------------------------------- pagination
    def paginate(self, fn: Callable[..., ApiResult], limit: int = 100, max_pages: int = 50,
                 items_key: str | None = None, **kwargs) -> Iterator[ApiResult]:
        """Offset pagination. Stops on a short page, on reaching `total`, or at max_pages."""
        offset = 0
        for _ in range(max_pages):
            r = fn(limit=limit, offset=offset, **kwargs)
            yield r
            if not r.ok:
                return
            rows = r.rows(items_key)
            total = r.data.get("total") if isinstance(r.data, dict) else None
            offset += len(rows)
            if len(rows) < limit or (isinstance(total, int) and offset >= total):
                return

    def iter_changes_cursor(self, since: str, limit: int = 100, max_pages: int = 10,
                            **kwargs) -> Iterator[ApiResult]:
        """Cursor pagination: re-use the returned nextSince as the next `since` (offset 0)."""
        cursor = since
        for _ in range(max_pages):
            r = self.changes(since=cursor, limit=limit, **kwargs)
            yield r
            if not r.ok or not isinstance(r.data, dict):
                return
            nxt = r.data.get("nextSince")
            if not nxt or nxt == cursor or not r.rows("changes"):
                return
            cursor = nxt

    # ---------------------------------------------------------------- reports
    def calls_df(self):
        import pandas as pd
        df = pd.DataFrame(self.calls)
        if df.empty:
            return df
        rate = pd.json_normalize(df["rate"]).add_prefix("rate.")
        return pd.concat([df.drop(columns=["rate"]), rate], axis=1)

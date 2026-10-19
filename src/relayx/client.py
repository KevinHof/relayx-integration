"""
HTTP client for the Relay X Regulatory API (v1).

Ported from legacy/relayx_client.py: same request wrapper, 429 handling and the
two hashes (raw bytes, canonical JSON). Changes against the legacy version:
- quota: the RateLimit-* headers are authoritative; no limit is hard-coded.
  When Remaining reaches 0 the client waits until RateLimit-Reset, which is
  parsed defensively (seconds to wait, or a Unix timestamp).
- 5xx and connection errors are retried a few times with backoff.
- persistence is left to the caller (extractors decide where raw goes).
- base URL defaults to api.relay-x.com, the host the contract serves.

The API key is read from the environment and never written or printed.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Callable

import requests

DEFAULT_BASE_URL = "https://api.relay-x.com/api/regulatory/v1"
API_PREFIX = "/api/regulatory/v1"
RATE_HEADERS = ("RateLimit-Limit", "RateLimit-Remaining", "RateLimit-Reset", "RateLimit-Policy",
                "Retry-After", "X-Key-Prefix")
BATCH_MAX = 50
BATCH_MAX_FULL = 25
# A RateLimit-Reset above this is read as a Unix timestamp, below as seconds to wait.
_EPOCH_THRESHOLD = 1_000_000_000


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def canonical_hash(obj: Any) -> str | None:
    """SHA-256 of canonical JSON (sorted keys, no whitespace). None if not JSON."""
    if obj is None or isinstance(obj, str):
        return None
    payload = json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def reset_wait_seconds(value: str | None, now: float | None = None) -> float | None:
    """Seconds until the quota window reopens, from a RateLimit-Reset header.

    Accepts either form seen in practice: a delay in seconds ("42") or a Unix
    timestamp ("1792419799"). Returns None when the header is absent or unreadable.
    """
    if value is None:
        return None
    try:
        v = float(value)
    except (TypeError, ValueError):
        return None
    if v >= _EPOCH_THRESHOLD:
        now = time.time() if now is None else now
        return max(0.0, v - now)
    return max(0.0, v)


def resolve_base_url(env_value: str | None) -> str:
    """RELAYX_BASE_URL may be the host only or include the API prefix."""
    base = (env_value or DEFAULT_BASE_URL).rstrip("/")
    return base if base.endswith(API_PREFIX) else base + API_PREFIX


@dataclass
class ApiResult:
    method: str
    path: str
    params: dict
    body_sent: Any
    status: int
    elapsed_s: float
    raw: bytes
    sha256_raw: str
    sha256_canonical: str | None
    rate: dict
    content_type: str | None
    requested_at: str
    attempt: int
    data: Any = None

    @property
    def ok(self) -> bool:
        return 200 <= self.status < 300

    def meta(self) -> dict:
        return {"method": self.method, "path": API_PREFIX + self.path, "params": self.params,
                "body_sent": self.body_sent, "status": self.status, "elapsed_s": self.elapsed_s,
                "bytes": len(self.raw), "sha256_raw": self.sha256_raw,
                "sha256_canonical": self.sha256_canonical, "rate": self.rate,
                "content_type": self.content_type, "requested_at": self.requested_at,
                "attempt": self.attempt}


@dataclass
class QuotaTracker:
    """Follows the RateLimit-* headers and estimates units consumed from them."""
    limit: int | None = None
    remaining: int | None = None
    reset_raw: str | None = None
    units_from_headers: int = 0
    _last_remaining: int | None = field(default=None, repr=False)

    def update(self, rate: dict) -> None:
        """Remaining going down = same window; going up (or first response) = new window,
        where everything spent so far counts (it may include other keys of the subscription)."""
        try:
            limit = int(rate["RateLimit-Limit"])
            remaining = int(rate["RateLimit-Remaining"])
        except (KeyError, TypeError, ValueError):
            return
        last = self._last_remaining
        if last is not None and remaining < last:
            self.units_from_headers += last - remaining
        else:
            self.units_from_headers += max(0, limit - remaining)
        self.limit, self.remaining, self.reset_raw = limit, remaining, rate.get("RateLimit-Reset")
        self._last_remaining = remaining


class RelayXClient:
    def __init__(
        self,
        api_key: str | None = None,
        base_url: str | None = None,
        max_retries: int = 3,
        timeout: int = 180,
        max_wait_s: float = 900.0,
        verbose: bool = True,
        sleep: Callable[[float], None] = time.sleep,
        session: requests.Session | None = None,
    ):
        self._api_key = api_key or os.environ.get("RELAYX_API_KEY")
        self.base_url = resolve_base_url(base_url or os.environ.get("RELAYX_BASE_URL"))
        self.max_retries = max_retries
        self.timeout = timeout
        self.max_wait_s = max_wait_s
        self.verbose = verbose
        self.sleep = sleep
        self.session = session or requests.Session()
        self.session.headers.update({"Accept": "application/json",
                                     "User-Agent": "covalo-relayx-integration/0.1"})
        self.quota = QuotaTracker()
        self.requests_sent = 0

    def __repr__(self) -> str:
        return f"<RelayXClient base={self.base_url} key={'set' if self._api_key else 'MISSING'}>"

    def _log(self, msg: str) -> None:
        if self.verbose:
            print(msg, flush=True)

    def _auth_headers(self, auth: bool) -> dict:
        if not auth:
            return {}
        if not self._api_key:
            raise RuntimeError("No API key: set RELAYX_API_KEY in the environment or .env")
        return {"X-Api-Key": self._api_key}

    def _wait(self, seconds: float, why: str) -> None:
        seconds = min(seconds, self.max_wait_s)
        self._log(f"  waiting {seconds:.0f}s ({why})")
        self.sleep(seconds)

    def wait_for_units(self, needed: int = 1) -> None:
        """Block until the last seen headers say `needed` units are available."""
        q = self.quota
        if q.remaining is not None and q.remaining < needed:
            w = reset_wait_seconds(q.reset_raw)
            self._wait((w if w is not None else 60) + 1, f"{q.remaining} units left, need {needed}")
            q.remaining = None  # unknown until the next response

    def request(self, method: str, path: str, params: dict | None = None, json_body: Any = None,
                auth: bool = True, units: int = 1) -> ApiResult:
        params = {k: v for k, v in (params or {}).items() if v is not None}
        url = f"{self.base_url}{path}"
        attempt = 0
        while True:
            attempt += 1
            if auth:
                self.wait_for_units(units)
            requested_at = utc_now()
            t0 = time.perf_counter()
            try:
                resp = self.session.request(method, url, params=params, json=json_body,
                                            timeout=self.timeout, headers=self._auth_headers(auth))
            except requests.RequestException as exc:
                if attempt <= self.max_retries:
                    self._wait(5 * attempt, f"connection error: {type(exc).__name__}")
                    continue
                raise
            elapsed = time.perf_counter() - t0
            self.requests_sent += 1
            raw = resp.content or b""
            rate = {h: resp.headers.get(h) for h in RATE_HEADERS if resp.headers.get(h) is not None}
            if auth:
                self.quota.update(rate)
            try:
                data = resp.json()
            except ValueError:
                data = resp.text
            result = ApiResult(
                method=method.upper(), path=path, params=params, body_sent=json_body,
                status=resp.status_code, elapsed_s=round(elapsed, 3), raw=raw,
                sha256_raw=hashlib.sha256(raw).hexdigest(), sha256_canonical=canonical_hash(data),
                rate=rate, content_type=resp.headers.get("Content-Type"),
                requested_at=requested_at, attempt=attempt, data=data)
            self._log(f"  {method.upper()} {path} {resp.status_code} {len(raw)}B "
                      f"remaining={rate.get('RateLimit-Remaining')}")

            if resp.status_code == 429 and attempt <= self.max_retries:
                w = reset_wait_seconds(rate.get("Retry-After"))
                if w is None:
                    w = reset_wait_seconds(rate.get("RateLimit-Reset"))
                self._wait((w if w is not None else 60) + 1, "429")
                continue
            if resp.status_code >= 500 and attempt <= self.max_retries:
                self._wait(10 * attempt, f"HTTP {resp.status_code}")
                continue
            return result

    # ------------------------------------------------------------ endpoints
    def health(self) -> ApiResult:
        return self.request("GET", "/health", auth=False)

    def changes(self, since: str, cursor: str | None = None, territory: str | None = None,
                legislator: str | None = None, limit: int | None = None) -> ApiResult:
        """One page of /changes. Page with `cursor` (the previous nextCursor), never offset."""
        return self.request("GET", "/changes", params={
            "since": since, "cursor": cursor, "territory": territory,
            "legislator": legislator, "limit": limit})

    def lookup_batch(self, items: list[dict], territory: str | None = None, view: str = "standard",
                     sections: str | None = None, limit: int | None = None,
                     as_of: str | None = None) -> ApiResult:
        """One call to /substances/lookup:batch. Each item costs one unit."""
        cap = BATCH_MAX_FULL if view == "full" else BATCH_MAX
        if not 1 <= len(items) <= cap:
            raise ValueError(f"batch size {len(items)} outside 1..{cap} for view={view}")
        body = {"items": items, "view": view, "territory": territory, "sections": sections,
                "limit": limit, "asOf": as_of}
        body = {k: v for k, v in body.items() if v is not None}
        return self.request("POST", "/substances/lookup:batch", json_body=body, units=len(items))

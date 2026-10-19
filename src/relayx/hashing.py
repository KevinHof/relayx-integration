"""
Canonical JSON and hashes. The single definition used for every payload hash
(raw.entry_version.payload_sha256, ApiResult.sha256_canonical, change detection).

Canonical JSON, as defined in ADR-001:
- object keys sorted by Unicode code point, recursively (json `sort_keys=True`);
- separators "," and ":" with no whitespace anywhere;
- non-ASCII characters written as themselves, not \\u escapes (`ensure_ascii=False`);
- encoded as UTF-8, no BOM, no trailing newline;
- values as parsed from the response by Python's json module: array order kept,
  numbers re-serialised by json (e.g. 1.0 stays 1.0, 1e2 becomes 100.0).
The SHA-256 is taken over those UTF-8 bytes and written as 64 lowercase hex characters.
"""
from __future__ import annotations

import hashlib
import json
from typing import Any


def canonical_json(obj: Any) -> bytes:
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
                      allow_nan=False).encode("utf-8")


def canonical_sha256(obj: Any) -> str:
    return hashlib.sha256(canonical_json(obj)).hexdigest()


def sha256_bytes(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()

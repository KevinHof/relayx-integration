import hashlib

import pytest

from relayx.hashing import canonical_json, canonical_sha256


def test_key_order_and_whitespace_do_not_matter():
    assert canonical_json({"b": 1, "a": {"d": [1, 2], "c": None}}) == b'{"a":{"c":null,"d":[1,2]},"b":1}'
    assert canonical_sha256({"b": 1, "a": 2}) == canonical_sha256({"a": 2, "b": 1})


def test_array_order_matters():
    assert canonical_sha256([1, 2]) != canonical_sha256([2, 1])


def test_non_ascii_is_utf8_not_escaped():
    out = canonical_json({"name": "Annex D — hors Appendices CITES", "t": "化"})
    assert out == '{"name":"Annex D — hors Appendices CITES","t":"化"}'.encode("utf-8")
    assert canonical_sha256({"x": "é"}) == hashlib.sha256('{"x":"é"}'.encode("utf-8")).hexdigest()


def test_nan_is_rejected():
    with pytest.raises(ValueError):
        canonical_json({"x": float("nan")})

import json

from relayx.api_extract import run_keyed, run_list
from relayx.client import ApiResult, QuotaTracker
from relayx.hashing import sha256_bytes


class FakeClient:
    def __init__(self, handler):
        self.handler = handler
        self.calls = []
        self.quota = QuotaTracker()
        self.requests_sent = 0

    def request(self, method, path, params=None, json_body=None, auth=True, units=1):
        self.calls.append((method, path, params, json_body))
        self.requests_sent += 1
        status, body = self.handler(method, path, params, json_body)
        raw = json.dumps(body).encode()
        return ApiResult(method, path, params or {}, json_body, status, 0.0, raw, sha256_bytes(raw), None,
                         {}, "application/json", "t", 1, body)


def test_list_pages_until_total(tmp_path):
    rows = [{"officialRef": str(i)} for i in range(5)]

    def h(method, path, params, body):
        o, l = params["offset"], params["limit"]
        return 200, {"total": 5, "returned": len(rows[o:o + l]), "texts": rows[o:o + l]}

    c = FakeClient(h)
    m = run_list(c, tmp_path / "r", "/texts", {"territory": "EU"}, limit=2)
    assert [p[2]["offset"] for p in c.calls] == [0, 2, 4]
    assert m["status"] == "complete" and m["calls"] == 3
    meta = json.loads((tmp_path / "r" / "call_00002.meta.json").read_text())
    assert meta["endpoint"] == "/texts" and meta["sha256_raw"]


def test_list_keeps_error_status(tmp_path):
    c = FakeClient(lambda *a: (403, {"error": "forbidden", "grantedScopes": ["read:public"]}))
    m = run_list(c, tmp_path / "r", "/allergens", {"territory": "EU"})
    assert m["calls"] == 1 and m["by_status"] == {"403": 1}


def test_keyed_requeues_truncated_batch_items(tmp_path):
    state = {"n": 0}

    def h(method, path, params, body):
        state["n"] += 1
        items = body["items"]
        if state["n"] == 1:   # quota runs out after the first two items
            return 200, {"truncated": True, "results": [{"index": 0, "ok": True}, {"index": 1, "ok": True}]}
        return 200, {"truncated": False, "results": [{"index": i, "ok": True} for i in range(len(items))]}

    spec = {"endpoint": "/substances/lookup:batch", "path": "/substances/lookup:batch", "method": "POST",
            "body": {"items": [{"cas": "1"}, {"cas": "2"}, {"cas": "3"}, {"cas": "4"}]},
            "source_ref": ["a", "b", "c", "d"], "units": 4}
    c = FakeClient(h)
    m = run_keyed(c, tmp_path / "r", "lookup", [spec])
    assert m["calls"] == 2
    assert c.calls[1][3]["items"] == [{"cas": "3"}, {"cas": "4"}]
    meta = json.loads((tmp_path / "r" / "call_00002.meta.json").read_text())
    assert meta["source_ref"] == ["c", "d"] and meta["units_requested"] == 2


def test_keyed_resume_skips_stored_calls(tmp_path):
    specs = [{"endpoint": "/x/{id}", "path": f"/x/{i}", "source_ref": {"id": i}} for i in range(3)]
    c1 = FakeClient(lambda *a: (200, {"ok": True}))
    rd = tmp_path / "r"
    # simulate an interruption after the first call
    run_keyed(c1, rd, "x", specs[:1])
    (rd / "manifest.json").write_text(json.dumps(json.loads((rd / "manifest.json").read_text()) | {"status": "running"}))
    (rd / "specs.json").write_text(json.dumps(specs))
    c2 = FakeClient(lambda *a: (200, {"ok": True}))
    m = run_keyed(c2, rd, "x", specs)
    assert [p[1] for p in c2.calls] == ["/x/1", "/x/2"] and m["calls"] == 3

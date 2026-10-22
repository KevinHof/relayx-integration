import json

import pytest

from relayx import covalo_lookup as cl
from relayx.covalo_lookup import Config, KeepAwake, LedgerCheck, LedgerMismatch, LookupRun, check_request
from relayx.lookup_values import VALUE_COLS, read_values, to_csv


class Clock:
    def __init__(self):
        self.t = 0.0
        self.slept = []

    def clock(self):
        return self.t

    def sleep(self, s):
        self.slept.append(s)
        self.t += s


class Resp:
    def __init__(self, status, body, headers=None):
        self.status_code = status
        self.content = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.headers = {"Content-Type": "application/json"} | (headers or {})


class Session:
    """Fake API: handler(call_index, items) -> (status, body, headers)."""

    def __init__(self, handler, clock):
        self.handler, self.clock, self.sent = handler, clock, []

    def post(self, url, data, timeout, headers):
        assert headers["X-Api-Key"] == "k" and "?" not in url
        body = json.loads(data)
        items = [list(i.values())[0] for i in body["items"]]
        self.sent.append(items)
        self.clock.t += 1
        return Resp(*self.handler(len(self.sent), items))


def ok(items, n=None, truncated=False, reason=None, bad=()):
    n = len(items) if n is None else n
    res = [{"index": i, "ok": True, "ingredientStatus": {"status": "HAS_DATA"}} if items[i] not in bad else
           {"index": i, "ok": False, "error": "name_too_short", "message": "too short"} for i in range(n)]
    return 200, {"requested": len(items), "returned": n, "truncated": truncated, "truncatedReason": reason,
                 "results": res}, {"RateLimit-Limit": "300", "RateLimit-Remaining": "250",
                                   "RateLimit-Reset": "1792419799", "RateLimit-Policy": "300;w=60"}


def values_file(tmp_path, n):
    rows = [{"seq": i + 1, "id_type": "CAS", "param": "cas", "value": f"v{i + 1}", "products": 1,
             "in_replay": False, "in_catalogue": False} for i in range(n)]
    p = tmp_path / "values.csv"
    p.write_bytes(to_csv(rows, VALUE_COLS))
    return p


def make(tmp_path, handler, n=60, clock=None, rd=None, **cfg):
    clock = clock or Clock()
    vf = values_file(tmp_path, n) if not (tmp_path / "values.csv").exists() else tmp_path / "values.csv"
    s = Session(handler, clock)
    run = LookupRun(rd or tmp_path / "run", read_values(vf), vf, Config(**({"rate_per_minute": 300} | cfg)),
                    session=s, api_key="k", base_url="https://api.test", sleep=clock.sleep, clock=clock.clock,
                    echo=lambda m: None)
    return run, s, clock


def test_unit_cap_stops_before_a_batch_would_exceed_it(tmp_path):
    run, s, _ = make(tmp_path, lambda c, items: ok(items), n=60, max_units=55)
    m = run.run()
    assert [len(x) for x in s.sent] == [25, 25]
    assert m["status"] == "partial" and m["stop_reason"].startswith("unit cap") and m["units_used"] == 50


def test_resend_after_truncation_never_exceeds_cap(tmp_path):
    run, s, _ = make(tmp_path, lambda c, items: ok(items, n=10, truncated=True, reason="quota") if c == 1 else ok(items),
                     n=25, max_units=30)
    m = run.run()
    # 25 sent, 10 evaluated; resending the 15 others would make 40 > 30
    assert [len(x) for x in s.sent] == [25] and m["stop_reason"].startswith("unit cap")
    assert m["items_recorded"] == 10


def test_resume_restarts_at_first_unrecorded_item_without_resending(tmp_path):
    def h(c, items):
        if c == 2:
            raise KeyboardInterrupt
        return ok(items)

    run, s, clock = make(tmp_path, h, n=60)
    m = run.run()
    assert m["status"] == "partial" and m["stop_reason"] == "interrupted (Ctrl+C)" and m["items_recorded"] == 25
    run2, s2, _ = make(tmp_path, lambda c, items: ok(items), n=60, clock=clock)
    m2 = run2.run()
    assert s2.sent[0][0] == "v26" and sum(len(x) for x in s2.sent) == 35
    assert m2["status"] == "complete" and m2["items_recorded"] == 60 and m2["calls"] == 3
    assert sorted(e["item"] for e in m2["ledger"]) == list(range(1, 61))


def test_resume_ignores_orphan_response_without_meta(tmp_path):
    run, s, clock = make(tmp_path, lambda c, items: ok(items), n=30, max_items=25)
    run.run()
    (tmp_path / "run" / "call_00002.json").write_bytes(b"{}")      # crash before its meta was written
    run2, s2, _ = make(tmp_path, lambda c, items: ok(items), n=30, clock=clock)
    m2 = run2.run()
    assert s2.sent == [["v26", "v27", "v28", "v29", "v30"]] and m2["orphan_calls"] == [2]
    assert (tmp_path / "run" / "call_00003.meta.json").exists()


def test_429_waits_retry_after_plus_two_and_resends_same_items(tmp_path):
    h = lambda c, items: (429, {"error": "quota"}, {"Retry-After": "7"}) if c == 1 else ok(items)
    run, s, clock = make(tmp_path, h, n=25)
    m = run.run()
    assert s.sent[0] == s.sent[1] and abs(sum(clock.slept) - 9) < 1e-6
    assert m["status"] == "complete" and m["units_used"] == 25 and m["by_status"] == {"429": 1, "200": 1}


def test_429_without_retry_after_waits_for_reset_plus_two(tmp_path, monkeypatch):
    monkeypatch.setattr(cl.time, "time", lambda: 1_800_000_000.0)
    h = lambda c, items: (429, {"error": "quota"}, {"RateLimit-Reset": "1800000030"}) if c == 1 else ok(items)
    run, s, clock = make(tmp_path, h, n=25)
    run.run()
    assert abs(sum(clock.slept) - 32) < 1e-6


def test_truncation_resends_exactly_items_after_last_returned_index(tmp_path):
    def h(c, items):
        if c == 1:
            r = ok(items, n=10, truncated=True, reason="time_budget")
            return r[0], r[1], r[2] | {"Retry-After": "3"}
        return ok(items)

    run, s, clock = make(tmp_path, h, n=40)
    m = run.run()
    assert s.sent[1] == [f"v{i}" for i in range(11, 26)]           # exactly the 15 unevaluated
    assert s.sent[2] == [f"v{i}" for i in range(26, 41)]
    assert 5 in clock.slept or abs(sum(clock.slept) - 5) < 1e-6
    assert m["truncations"] == [{"call_no": 1, "reason": "time_budget", "sent": 25, "returned": 10}]
    assert m["items_recorded"] == 40 and m["units_used"] == 55


def test_truncation_resend_survives_a_429(tmp_path):
    def h(c, items):
        if c == 1:
            return ok(items, n=5, truncated=True, reason="quota")
        if c == 2:
            return 429, {"error": "quota"}, {"Retry-After": "1"}
        return ok(items)

    run, s, _ = make(tmp_path, h, n=40)
    run.run()
    assert s.sent[1] == s.sent[2] == [f"v{i}" for i in range(6, 26)]


def test_ok_false_items_recorded_not_retried_and_listed(tmp_path):
    out = []
    run, s, _ = make(tmp_path, lambda c, items: ok(items, bad={"v3"}), n=25)
    run.echo = out.append
    m = run.run()
    assert len(s.sent) == 1 and m["status"] == "complete" and m["items_failed"] == 1
    assert m["failed_items"][0] | {} == {"item": 3, "type": "CAS", "value": "v3", "call_no": 1, "index": 2,
                                         "error": "name_too_short", "message": "too short"}
    assert any("v3" in line and "name_too_short" in line for line in out)


def test_400_stops_run_and_logs_full_body(tmp_path):
    body = {"error": "ambiguous_parameter", "message": "territory twice"}
    run, s, _ = make(tmp_path, lambda c, items: (400, body, {}), n=60)
    m = run.run()
    assert len(s.sent) == 1 and m["status"] == "failed" and "HTTP 400" in m["stop_reason"]
    assert json.dumps(body) in (tmp_path / "run" / "run.log").read_text(encoding="utf-8")


def test_401_stops_immediately(tmp_path):
    run, s, _ = make(tmp_path, lambda c, items: (401, {"error": "unauthorized"}, {}), n=60)
    assert run.run()["status"] == "failed" and len(s.sent) == 1


def test_5xx_retried_three_times_then_batch_counts_as_failed(tmp_path):
    run, s, _ = make(tmp_path, lambda c, items: (502, b"bad gateway", {}), n=25, max_consecutive_failures=2)
    m = run.run()
    assert len(s.sent) == 8 and m["status"] == "failed" and "consecutive" in m["stop_reason"]


def test_max_items_canary(tmp_path):
    run, s, _ = make(tmp_path, lambda c, items: ok(items), n=100, max_items=30)
    m = run.run()
    assert [len(x) for x in s.sent] == [25, 5] and s.sent[1][-1] == "v30"
    assert m["status"] == "complete" and m["params"]["items_selected"] == 30


def test_pacing_keeps_units_per_60s_within_rate(tmp_path):
    run, s, clock = make(tmp_path, lambda c, items: ok(items), n=75, rate_per_minute=50)
    run.run()
    assert len(s.sent) == 3 and 60 <= clock.t < 62      # 25+25 in the first minute, third after 60 s


def test_rate_above_300_refused():
    with pytest.raises(ValueError):
        Config(rate_per_minute=301).validate()


def test_check_request_refuses_repeated_parameter_and_non_iso_dates():
    with pytest.raises(ValueError):
        check_request("https://x/changes?territory=EU", {"territory": "FR"})
    with pytest.raises(ValueError):
        check_request("https://x/changes", {"since": "22/10/2026"})
    check_request("https://x/changes", {"since": "2026-10-22T00:00:00Z", "territory": "EU"})
    with pytest.raises(ValueError):
        check_request("https://x", None, {"items": [{"cas": "1", "inci": "A"}], "limit": 100})


def test_keep_awake_released_on_error():
    calls = []

    class K:
        def SetThreadExecutionState(self, flags):
            calls.append(flags)

    with pytest.raises(RuntimeError):
        with KeepAwake(K()):
            raise RuntimeError
    assert calls == [cl.ES_CONTINUOUS | cl.ES_SYSTEM_REQUIRED, cl.ES_CONTINUOUS]


def _stored(rd):
    for mp in sorted(rd.glob("call_*.meta.json")):
        meta = json.loads(mp.read_text(encoding="utf-8"))
        yield meta, json.loads((rd / f"call_{meta['call_no']:05d}.json").read_bytes())


def test_ledger_check_passes_and_detects_tampering(tmp_path):
    run, s, _ = make(tmp_path, lambda c, items: ok(items, n=10, truncated=True) if c == 1 else ok(items, bad={"v30"}), n=40)
    m = run.run()
    chk = LedgerCheck(m)
    for meta, body in _stored(tmp_path / "run"):
        chk.add(meta, body)
    assert chk.finish()["items_checked"] == 40
    bad = json.loads(json.dumps(m))
    bad["ledger"][3]["ingredient_status"] = "KNOWN_WITHOUT_DATA"
    chk = LedgerCheck(bad)
    with pytest.raises(LedgerMismatch):
        for meta, body in _stored(tmp_path / "run"):
            chk.add(meta, body)

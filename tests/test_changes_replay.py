import json

import pytest

from relayx.changes_replay import ReplayError, run
from relayx.client import ApiResult, QuotaTracker
from relayx.hashing import sha256_bytes
from relayx.replay_stats import compute, current_entries, has_identifier, load_rows


def row(lid, kind="FIRST_RECORDED", ks="2026-08-01T00:00:00Z", **ids):
    return {"logicalEntryId": lid, "changeKind": kind, "knownSince": ks, "territory": "EU",
            "annexType": "PROHIBITED", "entryScope": "SINGLE", "identifiers": ids, "validity": {}}


class FakeClient:
    """Serves a fixed list of pages; cursor i means 'page i'."""

    def __init__(self, pages):
        self.pages = pages
        self.cursors_seen = []
        self.quota = QuotaTracker()
        self.requests_sent = 0

    def changes(self, since, cursor=None, territory=None, legislator=None, limit=None):
        self.cursors_seen.append(cursor)
        i = 0 if cursor is None else int(cursor)
        rows = self.pages[i]
        last = i == len(self.pages) - 1
        body = {"since": since, "nextSince": rows[-1]["knownSince"],
                "nextCursor": None if last else str(i + 1),
                "total": sum(len(p) for p in self.pages[i:]), "returned": len(rows), "offset": 0,
                "truncated": not last, "territory": territory, "changes": rows}
        raw = json.dumps(body).encode()
        self.requests_sent += 1
        rate = {"RateLimit-Limit": "60", "RateLimit-Remaining": str(60 - self.requests_sent)}
        self.quota.update(rate)
        return ApiResult("GET", "/changes", {"cursor": cursor}, None, 200, 0.0, raw, sha256_bytes(raw),
                         None, rate, "application/json", "t", 1, body)


PAGES = [[row("a"), row("b")], [row("c"), row("a", "SUPERSEDED", "2026-08-02T00:00:00Z")], [row("d", cas="50-00-0")]]


def test_full_run_pages_by_cursor(tmp_path):
    c = FakeClient(PAGES)
    m = run(c, tmp_path / "r", "2000-01-01T00:00:00Z", "EU", limit=2)
    assert c.cursors_seen == [None, "1", "2"]
    assert m["status"] == "complete" and m["pages"] == 3 and m["rows"] == 5
    assert m["final_cursor"] is None and m["first_page_total"] == 5
    assert m["units_used_from_headers"] == 3


def test_interrupted_run_resumes_from_last_cursor(tmp_path):
    rd = tmp_path / "r"
    m1 = run(FakeClient(PAGES), rd, "2000-01-01T00:00:00Z", "EU", limit=2, max_pages=1)
    assert m1["status"] == "partial" and m1["last_cursor"] == "1"
    c2 = FakeClient(PAGES)
    m2 = run(c2, rd, "2000-01-01T00:00:00Z", "EU", limit=2)
    assert c2.cursors_seen == ["1", "2"]
    assert m2["status"] == "complete" and m2["pages"] == 3 and m2["rows"] == 5
    assert m2["requests"] == 3 and m2["resumed_count"] == 1
    assert sorted(p.name for p in rd.glob("page_*.json") if "meta" not in p.name) == [
        "page_00001.json", "page_00002.json", "page_00003.json"]


def test_resume_refuses_different_params(tmp_path):
    rd = tmp_path / "r"
    run(FakeClient(PAGES), rd, "2000-01-01T00:00:00Z", "EU", limit=2, max_pages=1)
    with pytest.raises(ReplayError):
        run(FakeClient(PAGES), rd, "2000-01-01T00:00:00Z", "GB", limit=2)


def test_stats_on_replay(tmp_path):
    rd = tmp_path / "r"
    run(FakeClient(PAGES), rd, "2000-01-01T00:00:00Z", "EU", limit=2)
    rows, metas = load_rows(rd)
    s = compute(rows, metas, today="2026-10-19")
    assert s["total_rows"] == 5 and s["distinct_logicalEntryId"] == 4
    assert s["versions_per_entry"] == {1: 3, 2: 1}
    assert s["entries_without_FIRST_RECORDED"] == 0
    assert s["current_entries"] == 4 and s["current_no_identifier"] == 3
    assert s["sum_returned"] == s["first_page_total"] == 5


def test_current_drops_retracted_and_keeps_latest():
    rows = [row("a"), row("a", "SUPERSEDED", "2026-08-02T00:00:00Z", cas="1-1-1"),
            row("b"), row("b", "RETRACTED", "2026-08-03T00:00:00Z")]
    cur = current_entries(rows)
    assert set(cur) == {"a"} and cur["a"]["changeKind"] == "SUPERSEDED"


def test_identifier_lists_count_as_identifiers():
    assert has_identifier(row("x", casList=["50-00-0"]))
    assert not has_identifier(row("x", name="Lead compounds", casList=[]))

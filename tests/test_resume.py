import json

import pytest

from relayx import api_extract, history_extract, substance_pilot
from relayx.api_extract import ResumeError, resume_keyed, resume_list, run_keyed, run_list

from test_api_extract import FakeClient


def _mark_running(rd):
    m = json.loads((rd / "manifest.json").read_text())
    (rd / "manifest.json").write_text(json.dumps(m | {"status": "running", "finished_at": None}))


def _interrupted_list(tmp_path):
    """A /texts run with 5 rows, limit 2, interrupted after its first page."""
    rows = [{"officialRef": str(i)} for i in range(5)]

    def h(method, path, params, body):
        o, l = params["offset"], params["limit"]
        return 200, {"total": 5, "returned": len(rows[o:o + l]), "texts": rows[o:o + l]}

    rd = tmp_path / "20261020T000000Z_texts_eu"
    first = FakeClient(lambda m, p, params, b: h(m, p, params, b) if params["offset"] == 0 else (_ for _ in ()).throw(KeyboardInterrupt()))
    with pytest.raises(KeyboardInterrupt):
        run_list(first, rd, "/texts", {"territory": "EU"}, limit=2)
    return rd, h


def test_resume_list_continues_offset_with_original_params(tmp_path):
    rd, h = _interrupted_list(tmp_path)
    c = FakeClient(h)
    m = resume_list(c, rd)
    assert [(p[2]["offset"], p[2]["limit"], p[2]["territory"]) for p in c.calls] == [(2, 2, "EU"), (4, 2, "EU")]
    assert m["status"] == "complete" and m["calls"] == 3


def test_resume_list_of_complete_run_makes_no_call(tmp_path):
    rd, h = _interrupted_list(tmp_path)
    resume_list(FakeClient(h), rd)
    c = FakeClient(h)
    assert resume_list(c, rd)["status"] == "complete" and c.calls == []


def test_resume_keyed_skips_stored_calls_and_keeps_params(tmp_path):
    specs = [{"endpoint": "/x/{id}", "path": f"/x/{i}", "source_ref": {"id": i}} for i in range(3)]
    rd = tmp_path / "r"
    seen = []

    def h(method, path, params, body):
        seen.append(path)
        if len(seen) == 2:
            raise KeyboardInterrupt
        return 200, {"ok": True}

    with pytest.raises(KeyboardInterrupt):
        run_keyed(FakeClient(h), rd, "entries_history", specs, {"selection": "narrow"})
    c = FakeClient(lambda *a: (200, {"ok": True}))
    m = resume_keyed(c, rd, "entries_history")
    assert [p[1] for p in c.calls] == ["/x/1", "/x/2"]
    assert m["status"] == "complete" and m["calls"] == 3 and m["params"] == {"selection": "narrow"}


def test_resume_keyed_refuses_wrong_feed_or_missing_specs(tmp_path):
    rd = tmp_path / "r"
    run_keyed(FakeClient(lambda *a: (200, {})), rd, "substance_pilot", [{"endpoint": "/x", "path": "/x"}])
    with pytest.raises(ResumeError, match="not 'entries_history'"):
        resume_keyed(FakeClient(lambda *a: (200, {})), rd, "entries_history")
    (rd / "specs.json").unlink()
    with pytest.raises(ResumeError, match="no specs.json"):
        resume_keyed(FakeClient(lambda *a: (200, {})), rd)
    with pytest.raises(ResumeError, match="no manifest.json"):
        resume_list(FakeClient(lambda *a: (200, {})), tmp_path / "missing")


def test_resume_list_refuses_keyed_run(tmp_path):
    rd = tmp_path / "r"
    run_keyed(FakeClient(lambda *a: (200, {})), rd, "entries_history", [{"endpoint": "/x", "path": "/x"}])
    with pytest.raises(ResumeError, match="not a list run"):
        resume_list(FakeClient(lambda *a: (200, {})), rd)


@pytest.mark.parametrize("module, argv, feed", [
    (history_extract, ["run"], "entries_history"),
    (substance_pilot, ["run"], "substance_pilot"),
])
def test_cli_resume_continues_in_given_directory(tmp_path, monkeypatch, capsys, module, argv, feed):
    rd = tmp_path / "r"
    specs = [{"endpoint": "/x/{id}", "path": f"/x/{i}"} for i in range(2)]
    run_keyed(FakeClient(lambda *a: (200, {})), rd, feed, specs[:1])
    (rd / "specs.json").write_text(json.dumps(specs))
    _mark_running(rd)
    c = FakeClient(lambda *a: (200, {}))
    monkeypatch.setattr(module, "RelayXClient", lambda: c)
    assert module.main(argv + ["--resume", str(rd), "--env", str(tmp_path / "none.env")]) == 0
    assert [p[1] for p in c.calls] == ["/x/1"]
    assert list(tmp_path.iterdir()) == [rd]          # no new run directory


def test_cli_lists_resume(tmp_path, monkeypatch):
    rd, h = _interrupted_list(tmp_path)
    c = FakeClient(h)
    monkeypatch.setattr(api_extract, "RelayXClient", lambda: c)
    assert api_extract.main(["lists", "--resume", str(rd), "--env", str(tmp_path / "none.env")]) == 0
    assert [p[2]["offset"] for p in c.calls] == [2, 4]

import zipfile

import pytest

from relayx.archive_run import ArchiveError, archive
from relayx.changes_replay import run
from test_changes_replay import PAGES, FakeClient


def make_run(tmp_path):
    rd = tmp_path / "raw" / "run1"
    run(FakeClient(PAGES), rd, "2000-01-01T00:00:00Z", "EU", limit=2)
    return rd


def test_archive_contains_run_and_checksums(tmp_path):
    rd = make_run(tmp_path)
    info = archive(rd, tmp_path / "archive")
    assert info["pages"] == 3 and info["run_status"] == "complete"
    with zipfile.ZipFile(info["archive"]) as z:
        names = set(z.namelist())
        assert "run1/manifest.json" in names and "run1/SHA256SUMS" in names
        assert "run1/page_00003.json" in names
        sums = z.read("run1/SHA256SUMS").decode()
    assert sums.count("\n") == info["files"]
    assert not (rd / "SHA256SUMS").exists()  # run dir untouched
    assert (tmp_path / "archive" / "run1.zip.sha256").exists()


def test_archive_refuses_tampered_page(tmp_path):
    rd = make_run(tmp_path)
    (rd / "page_00002.json").write_bytes(b"{}")
    with pytest.raises(ArchiveError, match="hash mismatch"):
        archive(rd, tmp_path / "archive")


def test_archive_refuses_overwrite_and_incomplete(tmp_path):
    rd = make_run(tmp_path)
    archive(rd, tmp_path / "archive")
    with pytest.raises(ArchiveError, match="already exists"):
        archive(rd, tmp_path / "archive")
    rd2 = tmp_path / "raw" / "run2"
    run(FakeClient(PAGES), rd2, "2000-01-01T00:00:00Z", "EU", limit=2, max_pages=1)
    with pytest.raises(ArchiveError, match="partial"):
        archive(rd2, tmp_path / "archive")

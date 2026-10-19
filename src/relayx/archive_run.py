"""
Zip one /changes run directory for archiving (ADR-001, retention).

Before zipping, every page file is checked against the sha256_raw in its meta file.
The archive holds the run directory unchanged plus a SHA256SUMS file (sha256 of every
file in the run), and is re-read and verified after writing. The run directory itself is
not modified. A <archive>.sha256 file is written next to the archive.

Usage:
    python -m relayx.archive_run data/raw/changes_replay/<run_id> [--out data/archive]
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import zipfile
from pathlib import Path

from .hashing import sha256_bytes

DEFAULT_OUT = Path("data/archive")


class ArchiveError(RuntimeError):
    pass


def verify_pages(run_dir: Path) -> int:
    """Check each page file against its meta sha256_raw. Returns the number of pages."""
    metas = sorted(run_dir.glob("page_*.meta.json"))
    if not metas:
        raise ArchiveError(f"no page meta files in {run_dir}")
    for mp in metas:
        meta = json.loads(mp.read_text(encoding="utf-8"))
        page = run_dir / mp.name.replace(".meta.json", ".json")
        if not page.exists():
            raise ArchiveError(f"missing page file {page.name}")
        if sha256_bytes(page.read_bytes()) != meta["sha256_raw"]:
            raise ArchiveError(f"hash mismatch for {page.name}")
    return len(metas)


def archive(run_dir: Path, out_dir: Path = DEFAULT_OUT, allow_incomplete: bool = False) -> dict:
    run_dir = run_dir.resolve()
    manifest_path = run_dir / "manifest.json"
    if not manifest_path.exists():
        raise ArchiveError(f"no manifest.json in {run_dir}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("status") != "complete" and not allow_incomplete:
        raise ArchiveError(f"run status is {manifest.get('status')!r}, not 'complete'")
    pages = verify_pages(run_dir)

    files = sorted(p for p in run_dir.rglob("*") if p.is_file())
    sums = {p.relative_to(run_dir).as_posix(): sha256_bytes(p.read_bytes()) for p in files}
    sums_text = "".join(f"{h}  {name}\n" for name, h in sums.items())

    out_dir.mkdir(parents=True, exist_ok=True)
    target = out_dir / f"{run_dir.name}.zip"
    if target.exists():
        raise ArchiveError(f"{target} already exists")
    prefix = run_dir.name
    with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for name in sums:
            z.write(run_dir / name, f"{prefix}/{name}")
        z.writestr(f"{prefix}/SHA256SUMS", sums_text)

    with zipfile.ZipFile(target) as z:
        for name, h in sums.items():
            if sha256_bytes(z.read(f"{prefix}/{name}")) != h:
                raise ArchiveError(f"verification failed for {name} in {target}")

    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    (out_dir / f"{target.name}.sha256").write_text(f"{digest}  {target.name}\n", encoding="utf-8")
    return {"archive": str(target), "archive_sha256": digest, "bytes": target.stat().st_size,
            "files": len(sums), "pages": pages, "run_status": manifest.get("status")}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT)
    ap.add_argument("--allow-incomplete", action="store_true")
    a = ap.parse_args(argv)
    print(json.dumps(archive(a.run_dir, a.out, a.allow_incomplete), indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())

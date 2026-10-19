"""
Database access. Every connection goes through RELAYX_DATABASE_URL (role relayx_app);
the admin URL is never used here (CLAUDE.md hard rule 1).
"""
from __future__ import annotations

import os
from pathlib import Path
from urllib.parse import urlparse

import psycopg


def connect(autocommit: bool = False) -> psycopg.Connection:
    url = os.environ["RELAYX_DATABASE_URL"]
    u = urlparse(url)
    if u.hostname not in ("localhost", "127.0.0.1", "::1") or u.port != 5434:
        raise RuntimeError("RELAYX_DATABASE_URL must point to the local database on port 5434")
    return psycopg.connect(url, autocommit=autocommit)


def run_sql_file(conn: psycopg.Connection, path: Path) -> None:
    """Execute a migration file. psql meta-commands (lines starting with a backslash) are
    skipped; the file manages its own transaction (BEGIN/COMMIT), so use autocommit."""
    sql = "\n".join(l for l in Path(path).read_text(encoding="utf-8").splitlines()
                    if not l.lstrip().startswith("\\"))
    conn.execute(sql)

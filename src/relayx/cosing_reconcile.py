"""
F3 provenance check: parse the CosIng CSV and reconcile it with the table it was loaded into
(PROVISIONAL, read-only). Reports encoding, delimiter, lines before the header, columns, row
count, and per column the number of values that differ between file and table, keyed on the
CosIng reference number, with the kind of difference.

    python -m relayx.cosing_reconcile data/cosing/cosing_clean.csv --table kevin.cosing_ingredients
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import re
import sys
from collections import Counter
from pathlib import Path

from .db import connect

TABLE_RE = re.compile(r"^[a-z_][a-z0-9_]*\.[a-z_][a-z0-9_]*$")
# File header -> table column, by position (checked against the names below).
EXPECTED = [("COSING Ref No", "cosing_ref_no"), ("INCI name", "inci_name"), ("INN name", "inn_name"),
            ("Ph. Eur. Name", "ph_eur_name"), ("CAS No", "cas_no"), ("EC No", "ec_no"),
            ("Chem/IUPAC Name / Description", "chem_iupac_name"), ("Restriction", "restriction"),
            ("Function", "function"), ("Update Date", "update_date")]


def detect_encoding(raw: bytes) -> str:
    if raw.startswith(b"\xef\xbb\xbf"):
        return "utf-8-sig"
    try:
        raw.decode("utf-8")
        return "utf-8"
    except UnicodeDecodeError:
        return "cp1252"


def read_csv(path: Path) -> dict:
    raw = path.read_bytes()
    enc = detect_encoding(raw)
    text = raw.decode(enc)
    sample = text[:20000]
    dialect = csv.Sniffer().sniff(sample, delimiters=",;\t|")
    lines = text.splitlines()
    header_idx = next(i for i, l in enumerate(lines) if l.startswith(EXPECTED[0][0]))
    rows = list(csv.reader(io.StringIO("\n".join(lines[header_idx:]) if header_idx else text),
                           delimiter=dialect.delimiter))
    header, data = rows[0], rows[1:]
    return {"encoding": enc, "delimiter": dialect.delimiter, "pre_header_lines": lines[:header_idx],
            "header": header, "rows": data, "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
            "physical_lines": len(lines), "rows_with_embedded_newline": sum(any("\n" in f for f in r) for r in data),
            "rows_wrong_width": sum(len(r) != len(header) for r in data)}


def diff_kind(f: str, t) -> str | None:
    """Kind of difference between a file value and a table value, or None if equal."""
    if t is None:
        return None if f == "" else ("file_blank_table_null" if f.strip() == "" else "table_null")
    t = str(t)
    if f == t:
        return None
    if f.strip() == t.strip():
        return "whitespace_trimmed"
    if f.strip().lower() == t.strip().lower():
        return "case"
    if f.lstrip("0 ") == t.lstrip("0 "):
        return "leading_zeros_or_spaces"
    return "other"


def reconcile(path: Path, table: str) -> dict:
    if not TABLE_RE.match(table):
        raise ValueError(f"table must be schema.table in lower case, got {table!r}")
    f = read_csv(path)
    header = f["header"]
    mapping_ok = [h for h, _ in EXPECTED] == header
    cols = [c for _, c in EXPECTED]
    with connect() as conn:
        conn.read_only = True
        trows = conn.execute(f"SELECT {', '.join(cols)} FROM {table}").fetchall()
    tbl = {}
    dup_table = Counter(r[0] for r in trows)
    for r in trows:
        tbl[r[0]] = r
    file_keys = Counter(r[0].strip() for r in f["rows"])
    out = {"file": str(path), "bytes": f["bytes"], "sha256": f["sha256"], "encoding": f["encoding"],
           "delimiter": f["delimiter"], "pre_header_lines": f["pre_header_lines"], "header": header,
           "header_matches_expected_mapping": mapping_ok, "data_rows": len(f["rows"]),
           "physical_lines": f["physical_lines"], "rows_with_embedded_newline": f["rows_with_embedded_newline"],
           "rows_wrong_width": f["rows_wrong_width"], "table": table, "table_rows": len(trows),
           "table_ref_no_duplicates": sum(1 for n in dup_table.values() if n > 1),
           "file_ref_no_duplicates": sum(1 for n in file_keys.values() if n > 1)}
    missing_in_table, kinds, examples = 0, {c: Counter() for c in cols[1:]}, {c: [] for c in cols[1:]}
    for r in f["rows"]:
        key = r[0].strip()
        t = tbl.get(int(key)) if key.isdigit() else None
        if t is None:
            missing_in_table += 1
            continue
        for i, c in enumerate(cols[1:], start=1):
            k = diff_kind(r[i], t[i])
            if k:
                kinds[c][k] += 1
                if len(examples[c]) < 5:
                    examples[c].append({"ref": key, "kind": k, "file": r[i][:80], "table": None if t[i] is None else str(t[i])[:80]})
    file_ids = {int(r[0].strip()) for r in f["rows"] if r[0].strip().isdigit()}
    out |= {"file_rows_not_in_table": missing_in_table,
            "table_rows_not_in_file": sum(1 for k in tbl if k not in file_ids),
            "differences": {c: dict(v) for c, v in kinds.items()},
            "examples": {c: v for c, v in examples.items() if v}}
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv_file", type=Path)
    ap.add_argument("--table", default="kevin.cosing_ingredients")
    ap.add_argument("--env", type=Path, default=Path(".env"))
    a = ap.parse_args(argv)
    from dotenv import load_dotenv
    load_dotenv(a.env)
    print(json.dumps(reconcile(a.csv_file, a.table), indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())

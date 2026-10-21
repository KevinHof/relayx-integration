from relayx.cosing_reconcile import EXPECTED, detect_encoding, diff_kind, read_csv


def test_diff_kind():
    assert diff_kind(" 50-00-0", " 50-00-0") is None
    assert diff_kind("", None) is None
    assert diff_kind(" ", None) == "file_blank_table_null"
    assert diff_kind(" 50-00-0", "50-00-0") == "whitespace_trimmed"
    assert diff_kind("Aqua", "AQUA") == "case"
    assert diff_kind("0123", "123") == "leading_zeros_or_spaces"
    assert diff_kind("a", "b") == "other"
    assert diff_kind("1", 1) is None


def test_detect_encoding():
    assert detect_encoding("é".encode("utf-8")) == "utf-8"
    assert detect_encoding(b"\xef\xbb\xbfx") == "utf-8-sig"
    assert detect_encoding("é".encode("cp1252")) == "cp1252"


def test_read_csv_quoted_fields_and_preamble(tmp_path):
    header = ",".join(h for h, _ in EXPECTED)
    body = '1, AQUA,,," 7732-18-5, 1-1-1", ,"line one\nline two",,SOLVENT,01/01/2020\n'
    p = tmp_path / "c.csv"
    p.write_text("Export date: 2020-12-31\n" + header + "\n" + body, encoding="utf-8")
    f = read_csv(p)
    assert f["pre_header_lines"] == ["Export date: 2020-12-31"]
    assert f["header"] == [h for h, _ in EXPECTED]
    assert len(f["rows"]) == 1 and f["rows"][0][4] == " 7732-18-5, 1-1-1"
    assert f["rows_with_embedded_newline"] == 1 and f["rows_wrong_width"] == 0

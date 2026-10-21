import pytest

from relayx.provisional_report import apply_params, split_report


def test_apply_params_fills_and_validates():
    assert apply_params("SELECT * FROM {{t}}", {"t": "kevin.cosing_ingredients"}) == "SELECT * FROM kevin.cosing_ingredients"
    with pytest.raises(ValueError, match="not a plain"):
        apply_params("SELECT * FROM {{t}}", {"t": "x; DROP TABLE y"})
    with pytest.raises(ValueError, match="missing --param"):
        apply_params("SELECT * FROM {{t}}", {})


def test_split_report_separates_setup_and_titled_sections():
    sql = (
        "CREATE TEMP TABLE t AS SELECT 1 AS x;\n"
        "-- REPORT\n"
        "\n"
        "-- a1. First\n"
        "SELECT x FROM t;\n"
        "\n"
        "-- a2. Second, title\n"
        "-- continued\n"
        "SELECT x + 1\n"
        "FROM t\n"
    )
    setup, sections = split_report(sql)
    assert setup == "CREATE TEMP TABLE t AS SELECT 1 AS x;"
    assert sections == [
        ("a1. First", "SELECT x FROM t"),
        ("a2. Second, title continued", "SELECT x + 1\nFROM t"),
    ]

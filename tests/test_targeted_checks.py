from relayx.targeted_checks import CONTAMINANTS, build_specs, cas_ok


def test_contaminant_cas_numbers_pass_check_digit():
    assert len(CONTAMINANTS) == 20
    assert [c for _, c in CONTAMINANTS if not cas_ok(c)] == []
    assert not cas_ok("7439-92-2")


def test_opinions_specs_batch_lookup_then_one_get_per_item():
    items = [{"cas": f"50-00-{i}", "stratum": "S"} for i in range(30)]
    specs = build_specs("opinions", items)
    batches = [s for s in specs if s.get("method") == "POST"]
    gets = [s for s in specs if s.get("method") is None]
    assert [b["units"] for b in batches] == [25, 5]
    assert batches[0]["body"]["view"] == "full" and batches[0]["body"]["territory"] == "EU"
    assert len(gets) == 30 and gets[0]["path"] == "/substances/opinions"
    assert sum(s.get("units", 1) for s in specs) == 60


def test_impurity_and_ifra_specs_are_single_gets():
    items = [{"cas": "50-00-0", "stratum": "S"}]
    assert build_specs("impurity", items)[0]["path"] == "/substances/impurity-limits"
    assert build_specs("ifra", items)[0]["params"] == {"cas": "50-00-0"}

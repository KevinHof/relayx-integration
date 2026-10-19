from relayx.completeness import draw_sample, evaluate, first_value


def cat(i, cas="", ec="", inci="", name="x"):
    stratum = "CAS" if cas else "EC_ONLY" if ec else "INCI_ONLY" if inci else "NAME_ONLY"
    return {"id": i, "cas_number": cas, "ec_number": ec, "inci_name": inci, "substance_name": name,
            "stratum": stratum}


def test_first_value_of_multivalue_cell():
    assert first_value(" 130066-44-3 | 31906-04-4") == "130066-44-3"


def test_sample_is_stratified_capped_and_reproducible():
    c = [cat(i, cas=f"{i}-00-0") for i in range(20)] + [cat(100 + i, ec=f"200-00{i}-0") for i in range(3)]
    s1 = draw_sample(c, {"CAS": 5, "EC_ONLY": 10})
    assert [x["stratum"] for x in s1].count("CAS") == 5
    assert [x["stratum"] for x in s1].count("EC_ONLY") == 3
    assert s1 == draw_sample(c, {"CAS": 5, "EC_ONLY": 10})
    assert all(x["param"] == ("cas" if x["stratum"] == "CAS" else "ec") for x in s1)


def test_evaluate_rates_and_misses():
    sample = [{"stratum": "CAS", "param": "cas", "value": "50-00-0", "catalogue_id": 1, "catalogue_row": {}},
              {"stratum": "NAME_ONLY", "param": "name", "value": "Lead compounds", "catalogue_id": 2,
               "catalogue_row": {}}]
    results = {
        0: {"ok": True, "total": 2, "returned": 2,
            "constraints": [{"logicalEntryId": "a"}, {"logicalEntryId": "b"}],
            "upcoming": {"constraints": [{"logicalEntryId": "c"}]}},
        1: {"ok": True, "total": 0, "returned": 0, "constraints": []},
    }
    rep = evaluate(sample, results, current_ids={"a"}, any_ids={"a", "c"})
    cas = rep["by_stratum"]["CAS"]
    assert cas["returned"] == 3 and cas["found_any_version"] == 2 and cas["found_current"] == 1
    assert cas["rate_any_version"] == round(2 / 3, 4)
    assert [m["logicalEntryId"] for m in rep["misses"]] == ["b"]
    assert [m["logicalEntryId"] for m in rep["found_not_current"]] == ["c"]
    assert rep["by_stratum"]["NAME_ONLY"]["rate_any_version"] is None

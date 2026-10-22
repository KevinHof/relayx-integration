from relayx.hashing import canonical_sha256
from relayx.load_raw import check_changes_run, duplicate_versions, version_key


def row(entry, known_since, event=None, change_kind="FIRST_RECORDED"):
    r = {"logicalEntryId": entry, "knownSince": known_since, "changeKind": change_kind}
    if event is not None:
        r |= {"event": event, "eventAt": known_since}
    return r


class FakeCursor:
    """Answers check_changes_run's four queries in order (no database)."""

    def __init__(self, payloads):
        self.payloads = payloads
        self.n = 0

    def execute(self, sql, params=None):
        self.n += 1

    def fetchone(self):
        n = len(self.payloads)
        return {1: (n, 1, str(n)), 2: (1, n, 0),
                3: (n, len({p["logicalEntryId"] for p in self.payloads}), 0)}[self.n]

    def __iter__(self):
        return iter((p, canonical_sha256(p)) for p in self.payloads)


class FakeConn:
    def __init__(self, payloads):
        self.c = FakeCursor(payloads)

    def cursor(self):
        return self.c


def test_retraction_repeating_recorded_known_since_is_accepted():
    rows = [row("a", "2026-10-01T00:00:00Z", "RECORDED", "RETRACTED"),
            row("a", "2026-10-01T00:00:00Z", "RETRACTION", "RETRACTED"),
            row("b", "2026-10-02T00:00:00Z", "RECORDED")]
    assert duplicate_versions(rows) == 0
    chk = check_changes_run(FakeConn(rows), "r")
    assert chk["duplicate_id_known_since_event"] == 0 and chk["ok"]


def test_true_duplicate_recorded_row_still_fails_the_check():
    rows = [row("a", "2026-10-01T00:00:00Z", "RECORDED"), row("a", "2026-10-01T00:00:00Z", "RECORDED")]
    chk = check_changes_run(FakeConn(rows), "r")
    assert chk["duplicate_id_known_since_event"] == 1 and not chk["ok"]


def test_rows_without_event_count_as_recorded():
    assert version_key(row("a", "2026-10-01T00:00:00Z")) == ("a", "2026-10-01T00:00:00Z", "RECORDED")
    old = [row("a", "2026-10-01T00:00:00Z"), row("a", "2026-10-02T00:00:00Z")]
    assert check_changes_run(FakeConn(old), "r")["ok"]
    # an old row and a new RECORDED row for the same version are the same version
    assert duplicate_versions([row("a", "2026-10-01T00:00:00Z"), row("a", "2026-10-01T00:00:00Z", "RECORDED")]) == 1
    assert not check_changes_run(FakeConn([row("a", "2026-10-01T00:00:00Z")] * 2), "r")["ok"]

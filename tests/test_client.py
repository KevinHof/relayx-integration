from relayx.client import QuotaTracker, reset_wait_seconds, resolve_base_url


def test_reset_seconds_form():
    assert reset_wait_seconds("42") == 42


def test_reset_unix_timestamp_form():
    assert reset_wait_seconds("1792419799", now=1792419739) == 60


def test_reset_timestamp_in_past_is_zero():
    assert reset_wait_seconds("1792419799", now=1792419999) == 0


def test_reset_missing_or_garbage():
    assert reset_wait_seconds(None) is None
    assert reset_wait_seconds("soon") is None


def test_base_url_host_only_gets_prefix():
    assert resolve_base_url("https://api.relay-x.com/") == "https://api.relay-x.com/api/regulatory/v1"
    assert resolve_base_url("https://api.relay-x.com/api/regulatory/v1") == "https://api.relay-x.com/api/regulatory/v1"


def test_quota_units_within_and_across_windows():
    q = QuotaTracker()
    q.update({"RateLimit-Limit": "60", "RateLimit-Remaining": "59", "RateLimit-Reset": "100"})
    q.update({"RateLimit-Limit": "60", "RateLimit-Remaining": "58", "RateLimit-Reset": "99"})
    assert q.units_from_headers == 2
    # new window: remaining jumps back up
    q.update({"RateLimit-Limit": "60", "RateLimit-Remaining": "59", "RateLimit-Reset": "60"})
    assert q.units_from_headers == 3
    assert q.remaining == 59


def test_quota_ignores_missing_headers():
    q = QuotaTracker()
    q.update({})
    assert q.units_from_headers == 0 and q.remaining is None
